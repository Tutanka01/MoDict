import AppKit
import SwiftUI

/// Visual states of the near-pointer composition preview.
enum HUDState: Equatable {
    case recording
    case transcribing
    case success
    case error(message: String, symbol: String)   // symbol = SF Symbol name
}

/// Owns the floating HUD panel and drives its content.
///
/// `show(_:)` is synchronous and instant — the panel is ordered on screen on
/// key-down, before any audio arrives, so perceived latency stays near zero. The
/// content then springs in. `hide()` animates out and *always* ends with
/// `orderOut`, so the panel can never linger on screen (a documented failure mode
/// of comparable apps).
@MainActor
final class HUDController {

    private let settings: SettingsStore
    private let model = HUDModel()

    private var panel: HUDPanel?
    private var isVisible = false
    private var hideWork: DispatchWorkItem?
    /// Captured on key-down so moving the mouse while speaking does not drag the
    /// composition card around. All later states stay at the same work point.
    private var sessionAnchor: NSPoint?

    /// EMA state for the mic level (attack while rising, release while falling).
    private var smoothedLevel: Float = 0

    /// Larger than the card so its spring, error shake and shadow never clip.
    private static let panelSize = CGSize(width: 460, height: 200)
    /// Tallest possible card (title row + three-line preview). Positioning
    /// clamps the *card*, not the panel, so the grown card can never cross
    /// into the menu-bar/notch band.
    private static let maxCardHeight: CGFloat = 130

    init(settings: SettingsStore) {
        self.settings = settings
    }

    // MARK: API

    func show(_ state: HUDState) {
        hideWork?.cancel()
        hideWork = nil

        ensurePanel()
        if state == .recording || sessionAnchor == nil || !isVisible {
            sessionAnchor = NSEvent.mouseLocation
        }
        position()

        if case .error = state { model.shakeToken &+= 1 }

        if isVisible {
            // Already on screen: animate the width/content change in place.
            withAnimation(Theme.stateSpring) { model.state = state }
            return
        }

        // First appearance. Order front now (instant), start from the pre-appear
        // transform, then spring in on the next runloop tick so SwiftUI captures
        // the start state.
        model.state = state
        model.contentScale = 0.92
        model.contentOpacity = 0
        panel?.orderFrontRegardless()
        isVisible = true

        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible else { return }
            withAnimation(Theme.appearSpring) {
                self.model.contentScale = 1
                self.model.contentOpacity = 1
            }
        }
    }

    /// Rolling transcript preview shown below the state row; nil clears it.
    /// Deliberately NOT animated: the bottom-pinned caption lays out each
    /// partial in one deterministic pass, and interpolating those layouts is
    /// what made the old preview swim. Only the one-time height growth animates
    /// (card-level spring on `hasPreview`).
    func setPartial(_ partial: PartialTranscript?) {
        guard model.partial != partial else { return }
        model.partial = partial
    }

    func setActionHint(_ hint: String) {
        guard model.actionHint != hint else { return }
        withAnimation(Theme.textSpring) { model.actionHint = hint }
    }

    func setLevel(_ level: Float) {
        let clamped = max(0, min(1, level))
        let alpha = clamped > smoothedLevel ? Theme.levelAttack : Theme.levelRelease
        smoothedLevel += alpha * (clamped - smoothedLevel)
        model.level = CGFloat(smoothedLevel)
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        smoothedLevel = 0
        model.level = 0

        withAnimation(.easeOut(duration: Theme.disappearDuration)) {
            model.contentScale = 0.96
            model.contentOpacity = 0
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.panel?.orderOut(nil)
            self.model.contentScale = 0.92   // reset for the next appearance
            self.model.partial = nil         // never leak text into the next session
            self.sessionAnchor = nil
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Theme.disappearDuration, execute: work)
    }

    // MARK: Panel

    private func ensurePanel() {
        guard panel == nil else { return }

        let rect = NSRect(origin: .zero, size: Self.panelSize)
        let panel = HUDPanel(contentRect: rect)

        let host = NSHostingView(rootView: HUDRootView(model: model))
        host.frame = rect
        host.autoresizingMask = [.width, .height]
        host.sizingOptions = []            // we drive the size via the panel frame
        panel.contentView = host

        self.panel = panel
    }

    /// Place the card by the pointer captured on key-down, or pinned to a screen
    /// edge when explicitly selected. Edge modes anchor the card's near edge and
    /// let it grow only toward the free side, so the preview expansion can never
    /// push the card into the menu-bar/notch band or off the bottom.
    private func position() {
        guard let panel else { return }

        let anchor = sessionAnchor ?? NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main
        guard let screen else { return }

        let visible = screen.visibleFrame
        let size = Self.panelSize

        // Highest allowed card top: below the menu bar when it is visible, and
        // below the camera housing when the menu bar auto-hides (visibleFrame
        // then reaches the physical top of a notched display).
        let safeTop = min(
            visible.maxY,
            screen.frame.maxY - screen.safeAreaInsets.top
        ) - Theme.hudTopGap

        var originX: CGFloat
        let originY: CGFloat
        switch settings.hudPosition {
        case .nearPointer:
            model.placement = .center
            let above = anchor.y + Theme.hudPointerCenterOffset
            let below = anchor.y - Theme.hudPointerCenterOffset
            let centerY = above + size.height / 2 <= visible.maxY ? above : below
            originX = anchor.x - size.width / 2
            // The card floats centered in the panel, inset by at least
            // (panel − max card) / 2 — clamp so even the fully grown card
            // stays below `safeTop` and inside the visible frame.
            let centerInset = (size.height - Self.maxCardHeight) / 2
            let topLimit = min(visible.maxY, safeTop + centerInset) - size.height
            originY = min(max(centerY - size.height / 2, visible.minY), topLimit)
        case .topCenter:
            model.placement = .top
            originX = visible.midX - size.width / 2
            // Card top lands exactly on safeTop; growth is downward only.
            originY = safeTop + Theme.hudCardEdgeMargin - size.height
        case .bottomCenter:
            model.placement = .bottom
            originX = visible.midX - size.width / 2
            // Card bottom fixed above the Dock line; growth is upward only.
            originY = visible.minY + Theme.hudBottomOffset - Theme.hudCardEdgeMargin
        }

        originX = min(max(originX, visible.minX), visible.maxX - size.width)
        panel.setFrame(
            NSRect(origin: NSPoint(x: originX, y: originY), size: size),
            display: false
        )
    }
}
