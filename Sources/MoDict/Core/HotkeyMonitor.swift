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

/// Global dictation hotkey via a session-level `CGEventTap`.
///
/// The tap listens for modifier changes (chosen key press/release) and key-downs
/// (combo detection + Esc-to-cancel). It only ever *swallows* one event: Esc
/// while dictation can still be cancelled. The dictation key is a bare modifier and
/// is never swallowed, so combos like ⌘C keep working.
///
/// The `CGEventTapCallBack` is a C function pointer and cannot capture context;
/// it recovers `self` from `userInfo` and hops onto the main actor. The run-loop
/// source is added to the *main* run loop, so the callback already executes on
/// the main thread — `MainActor.assumeIsolated` is therefore sound. Everything
/// inside stays trivial (flip state, dispatch); the real work (`onBegin` etc.)
/// is deferred to a later main-loop turn so a slow callback can never trip the
/// tap's internal timeout.
@MainActor
final class HotkeyMonitor {

    enum Mode: String, CaseIterable {
        case pushToTalk
        case toggle
        case hybrid
    }

    var mode: Mode = .hybrid
    /// The modifier that triggers dictation. Changing it mid-session would strand a
    /// press whose release lives on the old key, so any live session is cancelled.
    var key: DictationKey = .rightCommand {
        didSet {
            guard oldValue != key else { return }
            if isSessionActive { cancelSession() }
            keyDown = false
            pressStartedSession = false
            accidentalStart = false
            handsFree = false
        }
    }
    var onBegin: (() -> Bool)?
    var onEnd: (() -> Void)?
    var onCancel: (() -> Void)?
    /// Hybrid/toggle has become hands-free after the trigger key was released.
    /// The HUD uses this to replace the now-wrong "release" hint with "press again".
    var onHandsFree: (() -> Void)?
    var onPermissionLost: (() -> Void)?

    /// True between `onBegin` and the matching `onEnd`/`onCancel`.
    private(set) var isSessionActive = false

    // MARK: Tuning

    private static let escapeKeyCode: Int64 = 53               // kVK_Escape
    /// A hold this long or longer counts as push-to-talk (release stops); a
    /// briefer tap flips into hands-free/toggle.
    private static let holdThreshold: TimeInterval = 0.5
    /// A non-modifier key within this window of the press cancels the (accidental) start.
    private static let interruptWindow: TimeInterval = 1.0
    /// Minimum gap between two session *starts* (debounce).
    private static let cooldown: TimeInterval = 0.4
    private static let watchdogInterval: TimeInterval = 5.0
    /// Contiguous virtual-keycode range of the modifier keys (⌘⌥⌃⇧, caps, fn).
    private static let modifierKeyCodes: ClosedRange<Int64> = 54...63

    // MARK: Tap resources

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var watchdog: Timer?

    // MARK: Session state (mutated only on the main actor)

    /// Right ⌘ is physically held.
    private var keyDown = false
    /// The current key-down opened a fresh session (so its release is meaningful).
    private var pressStartedSession = false
    /// Recording continues after release; the next press ends it (toggle / hybrid tap).
    private var handsFree = false
    /// The just-started session can still be cancelled by a combo key.
    private var accidentalStart = false
    /// `systemUptime` of the last successful start (hold measurement + combo window).
    private var pressedAt: TimeInterval = 0
    /// `systemUptime` of the last session start (cooldown gate).
    private var lastSessionStart: TimeInterval = -.greatestFiniteMagnitude
    /// Set by the controller; Esc is swallowed while recording or transcribing.
    private var cancellationActive = false

    // MARK: Lifecycle

    @discardableResult
    func start() -> Bool {
        // Preflight only — never call CGRequestListenEventAccess() here: start()
        // runs on every launch, and the prompting variant re-raises the system
        // dialog each time. Prompting belongs behind an explicit user action
        // (onboarding / settings button).
        guard CGPreflightListenEventAccess() else { return false }
        if let tap, CGEvent.tapIsEnabled(tap: tap) { return true }
        stop()   // tear down any stale/disabled tap first

        let mask: CGEventMask =
            (CGEventMask(1) << CGEventType.flagsChanged.rawValue) |
            (CGEventMask(1) << CGEventType.keyDown.rawValue)

        // Non-capturing: recovers `self` from `userInfo`, runs on the main thread.
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            return MainActor.assumeIsolated {
                monitor.process(type: type, event: event)
            }
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,             // must be able to swallow Esc
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runLoopSource = source

        // Backstop against a silently disabled/"inert" tap (see research pitfalls).
        watchdog = Timer.scheduledTimer(withTimeInterval: Self.watchdogInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkTapHealth() }
        }
        return true
    }

    func stop() {
        watchdog?.invalidate()
        watchdog = nil
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            }
            CFMachPortInvalidate(tap)
        }
        tap = nil
        runLoopSource = nil
        resetState()
    }

    func setRecordingActive(_ active: Bool) {
        cancellationActive = active
    }

    // MARK: Event handling

    /// Runs inside the tap callback on the main actor. Returns `nil` only to
    /// swallow Esc while dictation is cancellable; every other event passes through untouched.
    private func process(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-arm: the system disables the tap on timeout or certain input.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            resetPressed()
            return Unmanaged.passUnretained(event)
        }

        let now = ProcessInfo.processInfo.systemUptime
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        switch type {
        case .flagsChanged:
            if keyCode == key.keyCode {
                // The device-dependent bit is specific to the chosen key: it clears
                // on release even if the left-hand sibling modifier is still held.
                let pressed = (event.flags.rawValue & key.flagMask) != 0
                if pressed { handlePress(now) } else { handleRelease(now) }
            }
            return Unmanaged.passUnretained(event)   // never swallow a modifier

        case .keyDown:
            if keyCode == Self.escapeKeyCode, cancellationActive {
                cancelSession()
                return nil                            // the one and only swallowed event
            }
            if keyDown, accidentalStart, isSessionActive,
               now - pressedAt <= Self.interruptWindow,
               !Self.modifierKeyCodes.contains(keyCode) {
                // A real keystroke during the grace window → this was a combo
                // (e.g. ⌘C), not a dictation start. Cancel, but let the key through.
                cancelSession()
            }
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handlePress(_ now: TimeInterval) {
        guard !keyDown else { return }   // dedupe repeated flagsChanged
        keyDown = true

        // A press while hands-free ends the running session (toggle / hybrid).
        // This is not a start, so the cooldown must not block it.
        if handsFree {
            endSession()
            return
        }
        guard !isSessionActive else { return }
        guard now - lastSessionStart >= Self.cooldown else { return }

        lastSessionStart = now
        pressedAt = now
        pressStartedSession = true
        accidentalStart = true
        beginSession()
    }

    private func handleRelease(_ now: TimeInterval) {
        guard keyDown else { return }
        keyDown = false

        // Only act if this key-down opened a still-live, still-held session.
        guard pressStartedSession, isSessionActive, !handsFree else {
            accidentalStart = false
            pressStartedSession = false
            return
        }
        accidentalStart = false
        let held = now - pressedAt

        switch mode {
        case .pushToTalk:
            endSession()
        case .toggle:
            handsFree = true                 // keep recording; next press stops
            pressStartedSession = false
            fire(onHandsFree)
        case .hybrid:
            if held >= Self.holdThreshold {
                endSession()                 // it was a hold → push-to-talk
            } else {
                handsFree = true             // brief tap → hands-free
                pressStartedSession = false
                fire(onHandsFree)
            }
        }
    }

    // MARK: Session transitions

    private func beginSession() {
        isSessionActive = true
        fireBegin()
    }

    private func endSession() {
        isSessionActive = false
        handsFree = false
        accidentalStart = false
        pressStartedSession = false
        fire(onEnd)
    }

    private func cancelSession() {
        isSessionActive = false
        handsFree = false
        accidentalStart = false
        pressStartedSession = false
        fire(onCancel)
    }

    // MARK: Recovery

    /// Clears "pressed" state after the tap was disabled — the release event was
    /// likely missed, so a physically-held session is ended to avoid a stuck
    /// recording. Hands-free sessions are left running; the re-armed tap will see
    /// the next press.
    private func resetPressed() {
        let endHeldSession = keyDown && isSessionActive
        keyDown = false
        accidentalStart = false
        pressStartedSession = false
        if endHeldSession {
            isSessionActive = false
            handsFree = false
            fire(onEnd)
        }
    }

    private func resetState() {
        keyDown = false
        handsFree = false
        accidentalStart = false
        pressStartedSession = false
        isSessionActive = false
        cancellationActive = false
    }

    private func checkTapHealth() {
        guard CGPreflightListenEventAccess() else {
            resetState()
            fire(onPermissionLost)
            return
        }
        guard let tap else { return }
        if !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
            resetPressed()
        }
    }

    private func rejectBeginIfStillOptimistic() {
        guard isSessionActive else { return }
        isSessionActive = false
        handsFree = false
        accidentalStart = false
        pressStartedSession = false
    }

    private func fireBegin() {
        guard let onBegin else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !onBegin() {
                    self.rejectBeginIfStillOptimistic()
                }
            }
        }
    }

    /// Callbacks are deferred one main-loop turn so heavy work (audio, HUD) never
    /// runs inside the tap callback.
    private func fire(_ callback: (() -> Void)?) {
        guard let callback else { return }
        DispatchQueue.main.async { callback() }
    }
}
