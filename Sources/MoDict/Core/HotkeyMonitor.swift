import Foundation
import CoreGraphics

/// The modifier that starts dictation. All four are right-hand / secondary keys
/// detected via `.flagsChanged` with a *device-specific* flag bit, so the bit
/// clears on release even when the left-hand sibling (e.g. left ⌘) is still held —
/// never use the device-independent `.maskCommand`/`.maskAlternate` etc.
enum DictationKey: String, CaseIterable {
    case rightCommand
    case rightOption
    case rightControl
    case globe

    /// Virtual keycode reported in `.flagsChanged` (`keyboardEventKeycode`).
    var keyCode: Int64 {
        switch self {
        case .rightCommand: return 54    // kVK_RightCommand
        case .rightOption:  return 61    // kVK_RightOption
        case .rightControl: return 62    // kVK_RightControl
        case .globe:        return 63    // kVK_Function (Globe / fn)
        }
    }

    /// Device-dependent bit, set in `event.flags` while the key is physically held.
    var flagMask: UInt64 {
        switch self {
        case .rightCommand: return 0x10        // NX_DEVICERCMDKEYMASK
        case .rightOption:  return 0x40        // NX_DEVICERALTKEYMASK
        case .rightControl: return 0x2000      // NX_DEVICERCTLKEYMASK
        case .globe:        return 0x800000    // NX_SECONDARYFNMASK (.maskSecondaryFn)
        }
    }

    /// Full label, e.g. for accessibility.
    var displayName: String {
        switch self {
        case .rightCommand: return "Right Command"
        case .rightOption:  return "Right Option"
        case .rightControl: return "Right Control"
        case .globe:        return "Globe (fn)"
        }
    }

    /// Compact label shown beneath the keycap in Settings.
    var shortName: String {
        switch self {
        case .rightCommand: return "Command"
        case .rightOption:  return "Option"
        case .rightControl: return "Control"
        case .globe:        return "Globe"
        }
    }

    /// SF Symbol drawn on the keycap.
    var keycapSymbol: String {
        switch self {
        case .rightCommand: return "command"
        case .rightOption:  return "option"
        case .rightControl: return "control"
        case .globe:        return "globe"
        }
    }

    /// Short status hint, e.g. "hold right ⌘" / "hold 🌐".
    var holdHint: String {
        switch self {
        case .rightCommand: return "hold right ⌘"
        case .rightOption:  return "hold right ⌥"
        case .rightControl: return "hold right ⌃"
        case .globe:        return "hold 🌐"
        }
    }

    /// Reads naturally mid-sentence, e.g. "the right ⌘ key" / "the Globe key".
    var inlineName: String {
        switch self {
        case .rightCommand: return "right ⌘"
        case .rightOption:  return "right ⌥"
        case .rightControl: return "right ⌃"
        case .globe:        return "Globe"
        }
    }
}

/// Global dictation hotkey. The controller's view of `HotkeyEventTaps` (the taps, on
/// their own thread) and `HotkeyGestureMachine` (the rules).
///
/// Only one event is ever swallowed: Esc while dictation can still be cancelled. The
/// dictation key is a bare modifier and is never swallowed, so combos like ⌘C keep
/// working. Callbacks arrive on the main queue, in the order the gestures happened,
/// so heavy work (audio, HUD) never runs anywhere near a tap callback.
@MainActor
final class HotkeyMonitor {

    enum Mode: String, CaseIterable {
        case pushToTalk
        case toggle
        case hybrid
    }

    var mode: Mode {
        get { taps.mode }
        set { taps.mode = newValue }
    }
    /// The modifier that triggers dictation. Changing it mid-session would strand a
    /// press whose release lives on the old key, so any live session is cancelled.
    var key: DictationKey {
        get { taps.key }
        set { taps.feed(.triggerKeyChanged(newValue)) }
    }
    var onBegin: (() -> Bool)?
    var onEnd: (() -> Void)?
    var onCancel: (() -> Void)?
    /// Hybrid/toggle has become hands-free after the trigger key was released.
    /// The HUD uses this to replace the now-wrong "release" hint with "press again".
    var onHandsFree: (() -> Void)?
    var onPermissionLost: (() -> Void)?

    /// True between `onBegin` and the matching `onEnd`/`onCancel`.
    var isSessionActive: Bool { taps.isSessionActive }
    /// `systemUptime` of the physical press behind the latest begin, which reaches the
    /// main actor a start grace later at best.
    var lastPressedAt: TimeInterval { taps.lastPressedAt }

    let taps = HotkeyEventTaps()
    /// Whether the controller took the session the last `.begin` opened. The tap thread
    /// keeps going while main is busy, so a chord can be queued behind a begin that is
    /// about to be refused; delivered, that cancel would hit a transcription in flight.
    private var sessionAccepted = false

    init() {
        taps.deliver = { [weak self] actions in
            MainActor.assumeIsolated { self?.perform(actions) }
        }
        taps.permissionLost = { [weak self] in
            MainActor.assumeIsolated { self?.onPermissionLost?() }
        }
    }

    deinit {
        taps.stop()
    }

    // MARK: Lifecycle

    @discardableResult
    func start() -> Bool {
        // Preflight only — never call CGRequestListenEventAccess() here: start()
        // runs on every launch, and the prompting variant re-raises the system
        // dialog each time. Prompting belongs behind an explicit user action
        // (onboarding / settings button).
        guard CGPreflightListenEventAccess() else { return false }
        return taps.start()
    }

    func stop() {
        taps.stop()
    }

    func setRecordingActive(_ active: Bool) {
        taps.feed(.recordingActive(active))
    }

    /// The controller ended the session by itself (mic failure, Pause, model switch).
    /// Forgets it silently, so the next press starts fresh instead of "ending"
    /// a hands-free session that no longer exists. No callback fires.
    func abandonSession() {
        taps.feed(.abandonSession)
    }

    // MARK: Delivery

    private func perform(_ actions: [HotkeyGestureMachine.Action]) {
        for action in actions {
            switch action {
            case .begin(let session):
                // Already over (stop, abandon, chord): nothing is left to begin, and
                // whatever followed it in the queue is dropped along with it.
                sessionAccepted = taps.isLive(session: session) && (onBegin?() ?? false)
                if !sessionAccepted {
                    taps.feed(.beginRejected(session: session))
                }
            case .end:
                if sessionAccepted { onEnd?() }
            case .handsFree:
                if sessionAccepted { onHandsFree?() }
            case .cancel:
                if sessionAccepted { onCancel?() }
            case .cancelFromEscape:
                onCancel?()
            case .scheduleBegin, .cancelScheduledBegin, .swallowEvent:
                break
            }
        }
    }
}
