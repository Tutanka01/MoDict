import Foundation

/// The dictation hotkey's gesture rules, with no event tap, thread or timer in sight.
///
/// `HotkeyEventTaps` turns what it sees into `Input`s and carries out the returned
/// `Action`s. The machine only ever reasons about the physical key (`isTriggerHeld`)
/// and the session that key opened, which is what makes every rule table-testable.
struct HotkeyGestureMachine {

    enum Input: Equatable, Sendable {
        /// A `.flagsChanged` for the trigger key.
        case triggerChanged(isDown: Bool)
        /// A key-down at the session tap: the one that can swallow Esc.
        case keyDown(keyCode: Int64)
        /// A key-down at the HID tap, which also sees shortcuts registered with
        /// Carbon (⌘Space, Spaceman) that never reach a session tap.
        case hidKeyDown(keyCode: Int64)
        /// The timer armed by `.scheduleBegin` fired.
        case graceElapsed
        /// The controller refused `.begin` for this session.
        case beginRejected(session: UInt64)
        /// A periodic read of the physical key state while the trigger is held.
        case physicalSample(isDown: Bool)
        /// The tap was disabled and is re-armed; events may have been lost meanwhile.
        case tapInterrupted(physicallyDown: Bool)
        case recordingActive(Bool)
        case triggerKeyChanged(DictationKey)
        /// The controller ended the session itself: forget it, tell nobody.
        case abandonSession
        /// The monitor stopped, or the permission went away.
        case reset
    }

    enum Action: Equatable, Sendable {
        case scheduleBegin(after: TimeInterval)
        case cancelScheduledBegin
        case begin(session: UInt64)
        case end
        case handsFree
        /// Ends the session the last `.begin` opened (chord, trigger key changed).
        case cancel
        /// Esc while cancellation is active. Unlike `.cancel` it is not tied to a
        /// hotkey session: it also stops a transcription already under way.
        case cancelFromEscape
        /// Do not pass the event being handled on to the system.
        case swallowEvent

        /// Whether the controller has to hear about it, as opposed to the tap thread.
        var reachesController: Bool {
            switch self {
            case .begin, .end, .handsFree, .cancel, .cancelFromEscape: return true
            case .scheduleBegin, .cancelScheduledBegin, .swallowEvent: return false
            }
        }
    }

    // MARK: Tuning

    /// A press waits this long before it opens anything: a key arriving meanwhile
    /// was a chord (⌘C), and no HUD, sound or microphone ever noticed.
    static let startGrace: TimeInterval = 0.04
    /// How long after the press a non-modifier key still reads as a shortcut.
    static let chordWindow: TimeInterval = 1.0
    /// A hold this long or longer counts as push-to-talk (release stops); a
    /// briefer tap flips into hands-free/toggle.
    static let holdThreshold: TimeInterval = 0.5
    /// Minimum gap between the physical presses of two session starts (debounce).
    static let cooldown: TimeInterval = 0.4
    /// A single sample can be transient; three in a row (300 ms) are a lost release.
    static let upSamplesForRelease = 3

    static let escapeKeyCode: Int64 = 53                       // kVK_Escape
    /// Sent by some keyboards and remappers (Karabiner) beside the Fn modifier change.
    static let globeKeyEventCode: Int64 = 179
    /// Contiguous virtual-keycode range of the modifier keys (⌘⌥⌃⇧, caps, fn).
    private static let modifierKeyCodes: ClosedRange<Int64> = 54...63

    // MARK: State

    private enum Phase: Equatable {
        case idle
        /// Pressed, begin scheduled, nothing visible has happened yet.
        case grace
        /// This press opened the session and the key is still down.
        case held(session: UInt64)
        /// Recording continues after release; the next press ends it.
        case handsFree(session: UInt64)
    }

    var mode: HotkeyMonitor.Mode
    private(set) var key: DictationKey
    /// The key is physically down, session or not. Polling runs exactly while this is true.
    private(set) var isTriggerHeld = false

    private var phase = Phase.idle
    /// The physical press of the current or latest hold.
    private(set) var pressedAt: TimeInterval = 0
    private var lastSessionStart: TimeInterval = -.greatestFiniteMagnitude
    private var lastSessionID: UInt64 = 0
    /// Set by the controller; Esc is swallowed while recording or transcribing.
    private var cancellationActive = false
    private var consecutiveUpSamples = 0
    private var sampledDownSincePress = false

    init(mode: HotkeyMonitor.Mode = .hybrid, key: DictationKey = .rightCommand) {
        self.mode = mode
        self.key = key
    }

    /// True between `.begin` and the matching end, cancel, rejection or abandon.
    var isSessionActive: Bool {
        switch phase {
        case .held, .handsFree: return true
        case .idle, .grace: return false
        }
    }

    func isLive(session: UInt64) -> Bool {
        phase == .held(session: session) || phase == .handsFree(session: session)
    }

    // MARK: Transitions

    mutating func handle(_ input: Input, now: TimeInterval) -> [Action] {
        switch input {
        case .triggerChanged(isDown: true):
            return press(now)
        case .triggerChanged(isDown: false):
            return release(now)
        case .keyDown(let keyCode):
            if keyCode == Self.escapeKeyCode, cancellationActive {
                return dropSession(notifying: nil) + [.cancelFromEscape, .swallowEvent]
            }
            return chord(keyCode, now)
        case .hidKeyDown(let keyCode):
            // Esc already acts through the session tap, where it can be swallowed.
            guard keyCode != Self.escapeKeyCode else { return [] }
            return chord(keyCode, now)
        case .graceElapsed:
            guard phase == .grace else { return [] }
            lastSessionID += 1
            lastSessionStart = pressedAt
            phase = .held(session: lastSessionID)
            return [.begin(session: lastSessionID)]
        case .beginRejected(let session):
            if isLive(session: session) { phase = .idle }
            return []
        case .physicalSample(let isDown):
            return sample(isDown: isDown, now)
        case .tapInterrupted(let physicallyDown):
            guard isTriggerHeld else { return [] }
            guard physicallyDown else { return release(now) }
            return sample(isDown: true, now)   // keep the session, the poller takes over
        case .recordingActive(let active):
            cancellationActive = active
            return []
        case .triggerKeyChanged(let newKey):
            guard newKey != key else { return [] }
            key = newKey
            // The release of a live press now lives on the old key.
            isTriggerHeld = false
            return dropSession(notifying: .cancel)
        case .abandonSession:
            return dropSession(notifying: nil)
        case .reset:
            isTriggerHeld = false
            cancellationActive = false
            return dropSession(notifying: nil)
        }
    }

    private mutating func press(_ now: TimeInterval) -> [Action] {
        guard !isTriggerHeld else { return [] }   // dedupe repeated flagsChanged
        isTriggerHeld = true
        pressedAt = now
        consecutiveUpSamples = 0
        sampledDownSincePress = false

        // A press while hands-free ends the running session (toggle / hybrid).
        // This is not a start, so the cooldown must not block it.
        if case .handsFree = phase {
            phase = .idle
            return [.end]
        }
        guard phase == .idle, now - lastSessionStart >= Self.cooldown else { return [] }
        phase = .grace
        return [.scheduleBegin(after: Self.startGrace)]
    }

    private mutating func release(_ now: TimeInterval) -> [Action] {
        guard isTriggerHeld else { return [] }
        isTriggerHeld = false

        switch phase {
        case .idle, .handsFree:
            return []
        case .grace:
            // Also in toggle and hybrid, where this tap could mean hands-free: under
            // 40 ms it is more likely contact bounce, and taking it as a tap would make
            // the real press that follows end the session it opened.
            phase = .idle
            return [.cancelScheduledBegin]
        case .held(let session):
            switch mode {
            case .pushToTalk:
                break
            case .toggle:
                phase = .handsFree(session: session)
                return [.handsFree]
            case .hybrid:
                if now - pressedAt < Self.holdThreshold {
                    phase = .handsFree(session: session)
                    return [.handsFree]
                }
            }
            phase = .idle
            return [.end]
        }
    }

    /// A real key soon after the press means the user was typing a shortcut. Later it
    /// is an accident at most, and cancelling would throw away a long dictation, so the
    /// recording carries on; if no words came of it, the speech gate drops the capture.
    /// Hands-free sessions never get here held.
    private mutating func chord(_ keyCode: Int64, _ now: TimeInterval) -> [Action] {
        guard isTriggerHeld,
              now - pressedAt <= Self.chordWindow,
              !Self.modifierKeyCodes.contains(keyCode),
              !(key == .globe && keyCode == Self.globeKeyEventCode)
        else { return [] }
        return dropSession(notifying: .cancel)
    }

    private mutating func sample(isDown: Bool, _ now: TimeInterval) -> [Action] {
        guard isTriggerHeld else { return [] }   // never infer a press from polling
        if isDown {
            sampledDownSincePress = true
            consecutiveUpSamples = 0
            return []
        }
        // A trigger the HID state has never reported down this hold comes from
        // something the sample cannot see (a software remapper, say). "Up" then
        // says nothing about the key, and acting on it would end every hold at 300 ms.
        guard sampledDownSincePress else { return [] }
        consecutiveUpSamples += 1
        guard consecutiveUpSamples >= Self.upSamplesForRelease else { return [] }
        return release(now)
    }

    private mutating func dropSession(notifying action: Action?) -> [Action] {
        let previous = phase
        phase = .idle
        switch previous {
        case .idle:
            return []
        case .grace:
            return [.cancelScheduledBegin]
        case .held, .handsFree:
            return action.map { [$0] } ?? []
        }
    }
}
