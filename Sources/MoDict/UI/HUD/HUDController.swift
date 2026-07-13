import AppKit
import SwiftUI

/// Visual states of the recording capsule. See Docs/DESIGN.md → "The HUD".
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

    /// EMA state for the mic level (attack while rising, release while falling).
    private var smoothedLevel: Float = 0

    /// The panel is intentionally larger than the widest capsule (the live
    /// transcript can reach `Theme.hudPartialMaxWidth`) so the capsule can grow,
    /// shake, and cast its shadow without ever being clipped by the window.
    private static let panelSize = CGSize(width: 480, height: 120)

    init(settings: SettingsStore) {
        self.settings = settings
    }

    // MARK: API

    func show(_ state: HUDState) {
        hideWork?.cancel()
        hideWork = nil

        ensurePanel()
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

    /// Live transcript shown next to the waveform (recording) or the dots
    /// (transcribing); nil clears it. Partials arrive ~1/s, so unlike `level`
    /// this can go through the observable model. `textSpring` (fully damped)
    /// drives both the capsule's width growth and the text cross-fades, so new
    /// words materialize in the same gesture that widens the capsule — no
    /// overshoot, no fighting between the two.
    func setPartial(_ partial: PartialTranscript?) {
        guard model.partial != partial else { return }
        withAnimation(Theme.textSpring) { model.partial = partial }
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

    /// Center the panel on the screen containing the mouse pointer, with the capsule
    /// `Theme.hudBottomOffset` from the chosen edge.
    private func position() {
        guard let panel else { return }

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let screen else { return }

        let visible = screen.visibleFrame
        let size = Self.panelSize
        let capsuleHalf = Theme.hudHeight / 2

        let centerX = visible.midX
        let capsuleCenterY: CGFloat
        switch settings.hudPosition {
        case .bottomCenter:
            capsuleCenterY = visible.minY + Theme.hudBottomOffset + capsuleHalf
        case .topCenter:
            capsuleCenterY = visible.maxY - Theme.hudBottomOffset - capsuleHalf
        }

        let origin = NSPoint(
            x: centerX - size.width / 2,
            y: capsuleCenterY - size.height / 2
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
    }
}
