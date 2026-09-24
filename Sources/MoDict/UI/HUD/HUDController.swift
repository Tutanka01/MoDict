import AppKit
import SwiftUI

/// Visual states of the composition card.
enum HUDState: Equatable {
    case recording
    case transcribing
    case success
    case error(message: String, symbol: String)   // symbol = SF Symbol name
}

/// Owns the floating HUD panel and drives its content.
///
/// `show(_:)` is synchronous and instant: the panel is ordered on screen on
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
    private var clockWork: DispatchWorkItem?
    /// Captured on key-down so moving the mouse or typing while speaking never
    /// drags the card around. All later states stay at the same anchor.
    private var sessionAnchor: Anchor?
    private var lastPartial: PartialTranscript?

    /// The text cursor lookup, injectable so tests never touch the AX API.
    var caretLocator: () -> NSRect? = { TextCaretLocator.caretRect() }

    /// EMA of the mic level for the silence watchdog. The bars ease on the
    /// display clock instead (`HUDLevelSmoother`).
    private var smoothedLevel: Float = 0

    /// Larger than the card so its spring, error shake and shadow never clip.
    static let panelSize = CGSize(width: 460, height: 200)
    /// Tallest possible card (state row + three-line preview). Positioning
    /// clamps the *card*, not the panel, so the grown card can never cross
    /// into the menu-bar/notch band.
    static let maxCardHeight: CGFloat = 130

    init(settings: SettingsStore) {
        self.settings = settings
    }

    // MARK: API

    func show(_ state: HUDState) {
        hideWork?.cancel()
        hideWork = nil

        ensurePanel()
        if state == .recording || sessionAnchor == nil || !isVisible {
            sessionAnchor = captureAnchor()
        }
        position()

        if case .error = state { model.shakeToken &+= 1 }
        if state == .recording {
            beginRecordingSession()
        } else {
            clockWork?.cancel()
        }
        postAccessibilityAnnouncement(for: state)

        if isVisible {
            // Already on screen: morph the same surface in place.
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

    /// Rolling transcript preview; nil clears it.
    /// Layout is deliberately NOT animated: the caption lays out each partial
    /// in one deterministic pass, and interpolating those layouts is what made
    /// the old preview swim. New words animate in the renderer instead, from
    /// the entrance stamps recorded here; only the card's growth animates.
    func setPartial(_ partial: PartialTranscript?) {
        guard lastPartial != partial else { return }
        lastPartial = partial
        model.setPartial(partial)
    }

    /// The preview currently shown (testing aid).
    var previewText: String {
        model.ink.text
    }

    /// The stop gesture. A persistent hint stays visible after the gesture is
    /// learned: hybrid's switch to hands-free changes how to stop, mid-session.
    func setActionHint(_ hint: String, persistent: Bool = false) {
        guard model.actionHint != hint || model.actionHintIsPersistent != persistent else { return }
        withAnimation(Theme.textSpring) {
            model.actionHint = hint
            model.actionHintIsPersistent = persistent
        }
    }

    /// Silence watchdog: "Hearing nothing — check your microphone".
    func setSilenceWarning(_ warning: Bool) {
        guard model.silenceWarning != warning else { return }
        withAnimation(Theme.textSpring) { model.silenceWarning = warning }
    }

    func setLevel(_ level: Float) {
        let clamped = max(0, min(1, level))
        let alpha = clamped > smoothedLevel ? Theme.levelAttack : Theme.levelRelease
        smoothedLevel += alpha * (clamped - smoothedLevel)
        model.level.target = CGFloat(clamped)
        onLevelSample?(smoothedLevel)
    }

    /// Silence-watchdog hook: every smoothed level sample lands here while the
    /// controller is visible.
    var onLevelSample: ((Float) -> Void)?

    /// Quietly answers "did the long dictation survive?" on success.
    func setInsertedWordCount(_ count: Int) {
        model.insertedWordCount = count
    }

    /// The count currently staged for the success card. Read access keeps the
    /// lifecycle testable: the count is set before `show(.success)` and must
    /// survive it, until `hide()` resets it for the next session.
    var insertedWordCount: Int? {
        model.insertedWordCount
    }

    /// Where the card is pinned for the current session (testing aid).
    var placement: HUDPlacement {
        model.placement
    }

    /// Whether the gesture and Esc hints are showing (testing aid).
    var showsGuidance: Bool {
        model.showsGuidance
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        smoothedLevel = 0
        model.level.target = 0
        model.sessionStartDate = nil
        clockWork?.cancel()

        withAnimation(.easeOut(duration: Theme.disappearDuration)) {
            model.contentScale = 0.9    // retracts toward its anchor: the cursor
            model.contentOpacity = 0
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.panel?.orderOut(nil)
            self.model.contentScale = 0.92   // reset for the next appearance
            self.setPartial(nil)             // never leak text into the next session
            self.model.insertedWordCount = nil   // nor the success word count
            self.model.silenceWarning = false
            self.model.showsClock = false
            self.model.level.reset()
            self.model.voice.reset()
            self.sessionAnchor = nil
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Theme.disappearDuration, execute: work)
    }

    // MARK: Session

    /// Guidance fades as the gesture is learned; the clock appears only once
    /// a dictation runs long.
    private func beginRecordingSession() {
        model.sessionStartDate = Date()
        model.voice.reset()
        model.showsGuidance = settings.gestureHintsRemaining > 0
        model.silenceWarning = false
        model.showsClock = false
        clockWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isVisible, self.model.state == .recording else { return }
            withAnimation(Theme.textSpring) { self.model.showsClock = true }
        }
        clockWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Theme.hudClockDelay, execute: work)
    }

    // MARK: Panel

    /// The HUD is a transparent, non-focusable overlay, invisible to the
    /// accessibility tree. Terminal outcomes are announced instead so VoiceOver
    /// users hear the same feedback sighted users see.
    private func postAccessibilityAnnouncement(for state: HUDState) {
        let message: String?
        switch state {
        case .success: message = "MoDict pasted your dictation."
        case .error(let messageText, _): message = "MoDict: \(messageText)"
        case .recording, .transcribing: message = nil   // announced state changes only
        }
        guard let message else { return }
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message
            ]
        )
    }

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

    // MARK: Positioning

    enum Anchor: Equatable {
        /// The focused app's text insertion point, in AppKit screen coordinates.
        case caret(NSRect)
        /// The mouse pointer, when the focused app reports no text cursor.
        case pointer(NSPoint)
    }

    private func captureAnchor() -> Anchor {
        // A caret rect is often zero-width, and an empty rect intersects
        // nothing, so test the point where the words will land.
        if settings.hudPosition == .nearPointer, let caret = caretLocator(),
           NSScreen.screens.contains(where: { $0.visibleFrame.contains(NSPoint(x: caret.minX, y: caret.midY)) }) {
            return .caret(caret)
        }
        return .pointer(NSEvent.mouseLocation)
    }

    private func position() {
        guard let panel else { return }
        let anchor = sessionAnchor ?? .pointer(NSEvent.mouseLocation)
        let point: NSPoint = switch anchor {
        case .caret(let rect): NSPoint(x: rect.midX, y: rect.midY)
        case .pointer(let point): point
        }
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        guard let screen else { return }

        // Highest allowed card top: below the menu bar when it is visible, and
        // below the camera housing when the menu bar auto-hides (visibleFrame
        // then reaches the physical top of a notched display).
        let safeTop = min(
            screen.visibleFrame.maxY,
            screen.frame.maxY - screen.safeAreaInsets.top
        ) - Theme.hudTopGap

        let layout = Self.layout(
            position: settings.hudPosition,
            anchor: anchor,
            visible: screen.visibleFrame,
            safeTop: safeTop
        )
        model.placement = layout.placement
        panel.setFrame(NSRect(origin: layout.origin, size: Self.panelSize), display: false)
    }

    /// Pure placement geometry (unit-tested): the panel origin and the card's
    /// pinned edges for a screen's visible frame.
    ///
    /// - Text cursor: the card hangs just below the cursor's line with its
    ///   content starting at the cursor's x, so the preview reads where the
    ///   words will land and grows down and to the right, away from your text.
    ///   It flips above the line when there is no room below.
    /// - Pointer (fallback): centered above the pointer, flipping below near
    ///   the top of the screen.
    /// - Edge modes pin the card's near edge and grow toward the free side.
    static func layout(position: SettingsStore.HUDPosition,
                       anchor: Anchor,
                       visible: NSRect,
                       safeTop: CGFloat) -> (origin: NSPoint, placement: HUDPlacement) {
        let size = panelSize
        let margin = Theme.hudCardEdgeMargin
        var originX: CGFloat
        let originY: CGFloat
        let placement: HUDPlacement

        switch (position, anchor) {
        case (.nearPointer, .caret(let caret)):
            originX = caret.minX - Theme.hudHorizontalPadding - margin
            let belowTop = min(caret.minY - Theme.hudCaretGap, safeTop)
            if belowTop - maxCardHeight >= visible.minY {
                placement = HUDPlacement(pin: .top, leading: true)
                originY = belowTop + margin - size.height
            } else {
                placement = HUDPlacement(pin: .bottom, leading: true)
                let aboveBottom = caret.maxY + Theme.hudCaretGap
                // The fully grown card must stay below the menu bar and notch.
                originY = min(aboveBottom, safeTop - maxCardHeight) - margin
            }
        case (.nearPointer, _):
            let point: NSPoint = switch anchor {
            case .caret(let rect): NSPoint(x: rect.midX, y: rect.midY)
            case .pointer(let point): point
            }
            placement = HUDPlacement(pin: .center)
            let above = point.y + Theme.hudPointerCenterOffset
            let below = point.y - Theme.hudPointerCenterOffset
            let centerY = above + size.height / 2 <= visible.maxY ? above : below
            originX = point.x - size.width / 2
            // The card floats centered in the panel, inset by at least
            // (panel − max card) / 2: clamp so even the fully grown card
            // stays below `safeTop` and inside the visible frame.
            let centerInset = (size.height - maxCardHeight) / 2
            let topLimit = min(visible.maxY, safeTop + centerInset) - size.height
            originY = min(max(centerY - size.height / 2, visible.minY), topLimit)
        case (.topCenter, _):
            placement = HUDPlacement(pin: .top)
            originX = visible.midX - size.width / 2
            // Card top lands exactly on safeTop; growth is downward only.
            originY = safeTop + margin - size.height
        case (.bottomCenter, _):
            placement = HUDPlacement(pin: .bottom)
            originX = visible.midX - size.width / 2
            // Card bottom fixed above the Dock line; growth is upward only.
            originY = visible.minY + Theme.hudBottomOffset - margin
        }

        originX = min(max(originX, visible.minX), visible.maxX - size.width)
        return (NSPoint(x: originX, y: originY), placement)
    }
}
