import AppKit
import Foundation
import Testing
@testable import MoDict

struct InterfaceStateTests {
    @Test
    func recentDictationsStayWithinTheMenuViewport() {
        #expect(MenuBar.historyViewportHeight(for: 1) == 80)
        #expect(MenuBar.historyViewportHeight(for: 3) == 220)
        #expect(MenuBar.historyViewportHeight(for: 5) == 220)
    }

    @Test @MainActor
    func menuShowsTheActualGestureAndAnActionForRecoverableStates() {
        func status(_ state: DictationController.ModelState = .ready,
                    enabled: Bool = true,
                    issue: DictationController.UserIssue? = nil,
                    phase: DictationController.Phase = .idle,
                    key: DictationKey = .rightCommand,
                    mode: HotkeyMonitor.Mode = .pushToTalk) -> MenuBar.Status {
            MenuBar.Status.make(phase: phase, modelState: state, model: .parakeetV3,
                                userIssue: issue, partial: nil, enabled: enabled,
                                dictationKey: key, mode: mode)
        }

        for key in DictationKey.allCases {
            #expect(status(key: key).detail == "Hold \(key.inlineName), speak, then release to paste.")
            #expect(status(key: key, mode: .toggle).detail == "Tap \(key.inlineName) to start. Tap again to paste.")
            #expect(status(key: key, mode: .hybrid).detail == "Hold \(key.inlineName) to talk, or tap for hands-free.")
        }
        #expect(status().action == nil)
        // Only plain readiness hides the status card; anything else shows it.
        #expect(status().isReady)
        #expect(status(.downloading(.init(phase: .ready, fraction: 1))).isReady)
        #expect(!status(enabled: false).isReady)
        #expect(!status(.needsDownload).isReady)
        #expect(!status(issue: .microphoneMissing).isReady)
        #expect(!status(phase: .recording).isReady)
        #expect(status(enabled: false).action == .resume)
        #expect(status(.needsDownload).action == .download)
        #expect(status(.needsAPIKey).action == .settings(.model))
        #expect(status(.failed("Offline")).action == .retry)
        #expect(status(issue: .inputMonitoringPermissionMissing).action == .settings(.general))
        #expect(status(issue: .microphoneMissing).action == .settings(.dictation))
        #expect(status(issue: .cloudTranscriptionFailed("Offline")).action == .settings(.model))
        #expect(status(issue: .secureInputBlocked).action == nil)
        // Action labels name the destination pane, not the gesture.
        #expect(status(issue: .inputMonitoringPermissionMissing).actionTitle == "Open General settings")
        #expect(status(issue: .microphoneMissing).actionTitle == "Choose a microphone")
        #expect(status(issue: .cloudTranscriptionFailed("Offline")).actionTitle == "Review model settings")
        #expect(status(issue: .secureInputBlocked).actionTitle == nil)
        #expect(status(enabled: false, phase: .recording).isRecording)
        #expect(status(phase: .transcribing).action == nil)
        #expect(status(.downloading(.init(phase: .downloading, fraction: 0.42))).fraction == 0.42)
        #expect(status(.downloading(.init(phase: .ready, fraction: 1)), mode: .toggle).detail == status(mode: .toggle).detail)
    }

    // MARK: HUD success word count

    /// Regression: `show(.success)` used to wipe the word count that
    /// `DictationController` stages *before* showing the success card, so
    /// "Pasted · N words" never rendered. The count must survive `show`, and
    /// only `hide()` may reset it for the next session.
    @Test @MainActor
    func successHUDKeepsTheWordCountStagedBeforeShowing() async throws {
        let suiteName = "MoDictTests.HUDController.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let controller = HUDController(settings: SettingsStore(defaults: defaults))
        controller.caretLocator = { nil }
        controller.setInsertedWordCount(12)
        controller.show(.success)
        #expect(controller.insertedWordCount == 12)

        // hide() resets the count from deferred main-queue work (after the
        // 0.18 s disappear animation) — yield to the main actor until it runs.
        controller.hide()
        for _ in 0..<50 where controller.insertedWordCount != nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(controller.insertedWordCount == nil)
    }

    // MARK: HUD placement

    private static let screen = NSRect(x: 0, y: 0, width: 1512, height: 944)
    private static let safeTop: CGFloat = 944 - 38 - Theme.hudTopGap

    /// The card's frame in screen space, from the panel origin and its pins.
    @MainActor
    private func cardEdges(_ layout: (origin: NSPoint, placement: HUDPlacement))
        -> (leading: CGFloat, top: CGFloat, bottom: CGFloat) {
        let margin = Theme.hudCardEdgeMargin
        let size = HUDController.panelSize
        return (layout.origin.x + margin,
                layout.origin.y + size.height - margin,
                layout.origin.y + margin)
    }

    @Test @MainActor
    func cardHangsBelowTheTextCursorWithTheWordsStartingAtItsX() {
        let caret = NSRect(x: 400, y: 600, width: 0, height: 18)
        let layout = HUDController.layout(position: .nearPointer, anchor: .caret(caret),
                                          visible: Self.screen, safeTop: Self.safeTop)
        #expect(layout.placement == HUDPlacement(pin: .top, leading: true))
        let card = cardEdges(layout)
        #expect(card.top == caret.minY - Theme.hudCaretGap)
        #expect(card.leading + Theme.hudHorizontalPadding == caret.minX)
    }

    @Test @MainActor
    func cardFlipsAboveACursorNearTheBottomAndStaysBelowTheMenuBar() {
        let low = NSRect(x: 400, y: 40, width: 0, height: 18)
        let above = HUDController.layout(position: .nearPointer, anchor: .caret(low),
                                         visible: Self.screen, safeTop: Self.safeTop)
        #expect(above.placement == HUDPlacement(pin: .bottom, leading: true))
        #expect(cardEdges(above).bottom == low.maxY + Theme.hudCaretGap)

        // A cursor right under the menu bar in a very short visible frame:
        // the grown card may never cross safeTop.
        let short = NSRect(x: 0, y: 700, width: 1512, height: 200)
        let high = NSRect(x: 400, y: 790, width: 0, height: 18)
        let clamped = HUDController.layout(position: .nearPointer, anchor: .caret(high),
                                           visible: short, safeTop: 890)
        #expect(cardEdges(clamped).bottom + HUDController.maxCardHeight <= 890)
    }

    @Test @MainActor
    func cardStaysOnScreenNearTheRightEdge() {
        let caret = NSRect(x: 1500, y: 600, width: 0, height: 18)
        let layout = HUDController.layout(position: .nearPointer, anchor: .caret(caret),
                                          visible: Self.screen, safeTop: Self.safeTop)
        #expect(layout.origin.x + HUDController.panelSize.width <= Self.screen.maxX)
        #expect(layout.origin.x >= Self.screen.minX)
    }

    @Test @MainActor
    func pointerFallbackAndEdgeModesKeepTheirCenteredPlacement() {
        let pointer = HUDController.layout(position: .nearPointer, anchor: .pointer(NSPoint(x: 700, y: 400)),
                                           visible: Self.screen, safeTop: Self.safeTop)
        #expect(pointer.placement == HUDPlacement(pin: .center))
        #expect(pointer.origin.x + HUDController.panelSize.width / 2 == 700)

        let caret = HUDController.Anchor.caret(NSRect(x: 400, y: 600, width: 0, height: 18))
        let top = HUDController.layout(position: .topCenter, anchor: caret,
                                       visible: Self.screen, safeTop: Self.safeTop)
        #expect(top.placement == HUDPlacement(pin: .top))
        #expect(cardEdges(top).top == Self.safeTop)
        let bottom = HUDController.layout(position: .bottomCenter, anchor: caret,
                                          visible: Self.screen, safeTop: Self.safeTop)
        #expect(bottom.placement == HUDPlacement(pin: .bottom))
    }

    @Test
    func accessibilityCaretRectsConvertAndImplausibleOnesAreRejected() {
        let converted = TextCaretLocator.appKitRect(fromAX: CGRect(x: 120, y: 100, width: 0, height: 20),
                                                    primaryScreenHeight: 1000)
        #expect(converted == NSRect(x: 120, y: 880, width: 0, height: 20))

        #expect(TextCaretLocator.isPlausibleCaret(CGRect(x: 120, y: 100, width: 0, height: 18)))
        #expect(!TextCaretLocator.isPlausibleCaret(.zero))
        #expect(!TextCaretLocator.isPlausibleCaret(CGRect(x: 0, y: 0, width: 2, height: 18)))
        #expect(!TextCaretLocator.isPlausibleCaret(CGRect(x: 10, y: 10, width: 800, height: 600)))
        #expect(!TextCaretLocator.isPlausibleCaret(CGRect(x: 10, y: 10, width: 1, height: 1)))
        #expect(!TextCaretLocator.isPlausibleCaret(CGRect(x: CGFloat.nan, y: 10, width: 0, height: 18)))
    }

    @Test @MainActor
    func hudGuidanceFollowsTheLearnedGesture() {
        let suiteName = "MoDictTests.HUDGuidance.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SettingsStore(defaults: defaults)
        let controller = HUDController(settings: settings)
        controller.caretLocator = { nil }

        controller.show(.recording)
        #expect(controller.showsGuidance)
        controller.hide()

        for _ in 0..<SettingsStore.guidedDictations { settings.recordGuidedDictation() }
        controller.show(.recording)
        #expect(!controller.showsGuidance)
        controller.hide()
    }

    // MARK: Waveform level

    /// The microphone reports ~12 levels a second; the bars must glide between
    /// them on the display clock: quick to rise, slower to fall, never
    /// overshooting, and never jumping after a long gap between frames.
    @Test
    func waveformLevelEasesPerFrameWithoutJumpsOrOvershoot() {
        let smoother = HUDLevelSmoother()
        var t: TimeInterval = 100
        #expect(smoother.value(at: t) == 0)

        smoother.target = 1
        var previous: CGFloat = 0
        for _ in 0..<12 {           // 100 ms at 120 Hz
            t += 1.0 / 120
            let value = smoother.value(at: t)
            #expect(value > previous)
            #expect(value - previous < 0.25)   // no visible step
            #expect(value <= 1)
            previous = value
        }
        #expect(previous > 0.85)

        smoother.target = 0
        for _ in 0..<12 { t += 1.0 / 120; previous = smoother.value(at: t) }
        #expect(previous > 0.3)     // release is slower than attack
        #expect(previous < 0.85)

        // A paused timeline resuming after seconds advances at most one step.
        smoother.target = 1
        let before = smoother.value(at: t)
        let after = smoother.value(at: t + 5)
        #expect(after - before < 0.7)

        smoother.reset()
        #expect(smoother.value == 0 && smoother.target == 0)
    }

    // MARK: Voice activity

    /// Voice holds the caret solid only above the threshold; releasing
    /// starts the settle clock once, and listening again clears it.
    @Test
    func voiceActivityTracksVoiceAndSettle() {
        let voice = HUDVoiceActivity()
        let t: TimeInterval = 100

        voice.advance(to: t, level: 0.02, listening: true)
        #expect(voice.lastVoiceTime == -.infinity)     // below the voice threshold
        voice.advance(to: t + 0.1, level: 0.5, listening: true)
        #expect(voice.lastVoiceTime == t + 0.1)
        #expect(voice.settleStart == nil)

        // Released: no more voice is heard and the settle clock starts once.
        voice.advance(to: t + 0.2, level: 0.9, listening: false)
        voice.advance(to: t + 0.3, level: 0.9, listening: false)
        #expect(voice.settleStart == t + 0.2)
        #expect(voice.lastVoiceTime == t + 0.1)

        voice.advance(to: t + 1, level: 0.4, listening: true)
        #expect(voice.settleStart == nil)
        #expect(voice.lastVoiceTime == t + 1)

        voice.reset()
        #expect(voice.lastVoiceTime == -.infinity && voice.settleStart == nil)
    }

    /// Like a caret while typing: solid while you speak, blinking at rest,
    /// never blinking under Reduce Motion.
    @Test
    func caretStaysSolidWhileSpeakingAndBlinksAtRest() {
        let t: TimeInterval = 500
        #expect(HUDVoiceActivity.caretOpacity(at: t, lastActivity: t - 0.2, settling: false, reduceMotion: false) == 1)
        let off = t + 0.5 + Theme.caretBlinkPeriod / 2
        #expect(HUDVoiceActivity.caretOpacity(at: off, lastActivity: t, settling: false, reduceMotion: false) < 0.05)
        #expect(HUDVoiceActivity.caretOpacity(at: off, lastActivity: t, settling: false, reduceMotion: true) == 1)
    }

    // MARK: Preview ink

    /// New characters are stamped when they appear; the unchanged prefix
    /// keeps its stamps, so only genuinely new or revised words animate.
    @Test
    func inkStampsOnlyNewAndRevisedCharacters() {
        func partial(_ confirmed: String, _ volatile: String) -> PartialTranscript {
            PartialTranscript(confirmedText: confirmed, volatileText: volatile)
        }
        var ink = HUDInk()
        ink.update(partial("", "Bonjour"), at: 10)
        #expect(ink.text == "Bonjour")
        #expect(ink.stamps.allSatisfy { $0 == HUDInk.Stamp(born: 10, lit: nil) })

        // The word is confirmed and new words arrive.
        ink.update(partial("Bonjour", "à tous"), at: 10.5)
        #expect(ink.text == "Bonjour à tous")
        #expect(ink.stamps.prefix(7).allSatisfy { $0 == HUDInk.Stamp(born: 10, lit: 10.5) })
        #expect(ink.stamps.dropFirst(7).allSatisfy { $0 == HUDInk.Stamp(born: 10.5, lit: nil) })
        #expect(ink.lastChange == 10.5)

        // A revision re-stamps from the first differing character only.
        ink.update(partial("Bonjour à", "tout"), at: 11)
        #expect(ink.text == "Bonjour à tout")
        #expect(ink.stamps[12].born == 10.5)
        #expect(ink.stamps[13] == HUDInk.Stamp(born: 11, lit: nil))
        #expect(ink.stamps[8].lit == 11)               // "à" just confirmed

        // Long-finished entrances collapse to 0 so settled text is one run;
        // the words confirmed just now are still brightening.
        ink.update(partial("Bonjour à tout", ""), at: 20)
        #expect(ink.stamps.allSatisfy { $0.born == 0 })
        #expect(ink.stamps.prefix(9).allSatisfy { $0.lit == 0 })
        #expect(ink.segments().map(\.text) == ["Bonjour à", " tout"])
        // Confirming words is not typing: the caret clock keeps the last edit.
        #expect(ink.lastChange == 11)

        ink.update(partial("Bonjour à tout", ""), at: 30)
        #expect(ink.segments().map(\.text) == ["Bonjour à tout"])
        #expect(ink.lastChange == 11)

        ink.update(nil, at: 22)
        #expect(ink.isEmpty && ink.segments().isEmpty)
    }

    /// Only the recent tail is laid out, cut on a word boundary.
    @Test
    func inkTailIsBoundedAndCutOnAWord() {
        var ink = HUDInk()
        let words = (1...80).map { "word\($0)" }.joined(separator: " ")
        ink.update(PartialTranscript(confirmedText: words, volatileText: ""), at: 1)
        let tail = ink.segments(limit: 60).map(\.text).joined()
        #expect(tail.count <= 60)
        #expect(tail.hasSuffix("word80"))
        #expect(tail.hasPrefix("word"))
        #expect(words.hasSuffix(tail))
    }

    /// The preview never leaks into the next session.
    @Test @MainActor
    func hudPreviewClearsWhenTheCardHides() async throws {
        let suiteName = "MoDictTests.HUDPreview.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let controller = HUDController(settings: SettingsStore(defaults: defaults))
        controller.caretLocator = { nil }
        controller.show(.recording)
        controller.setPartial(PartialTranscript(confirmedText: "Hello", volatileText: "there"))
        #expect(controller.previewText == "Hello there")

        controller.hide()
        for _ in 0..<50 where !controller.previewText.isEmpty {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(controller.previewText.isEmpty)
    }
}
