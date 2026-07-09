import Foundation
import CoreGraphics

/// Global right-⌘ hotkey via a session-level `CGEventTap`.
///
/// The tap listens for modifier changes (right ⌘ press/release) and key-downs
/// (combo detection + Esc-to-cancel). It only ever *swallows* one event: Esc
/// while a recording is active. Right ⌘ is a bare modifier and is never
/// swallowed, so combos like ⌘C keep working.
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
    var onBegin: (() -> Void)?
    var onEnd: (() -> Void)?
    var onCancel: (() -> Void)?

    /// True between `onBegin` and the matching `onEnd`/`onCancel`.
    private(set) var isSessionActive = false

    // MARK: Tuning

    private static let rightCommandKeyCode: Int64 = 54          // kVK_RightCommand
    private static let escapeKeyCode: Int64 = 53               // kVK_Escape
    private static let rightCommandFlagMask: UInt64 = 0x10     // NX_DEVICERCMDKEYMASK
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
    /// Set by the controller; Esc is only swallowed while this is true.
    private var recordingActive = false

    // MARK: Lifecycle

    @discardableResult
    func start() -> Bool {
        guard CGPreflightListenEventAccess() else {
            CGRequestListenEventAccess()   // surface the Input Monitoring prompt
            return false
        }
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
        recordingActive = active
    }

    // MARK: Event handling

    /// Runs inside the tap callback on the main actor. Returns `nil` only to
    /// swallow Esc while recording; every other event passes through untouched.
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
            if keyCode == Self.rightCommandKeyCode {
                // The device-dependent bit is right-⌘-specific: it clears on
                // release even if the *left* ⌘ is still held.
                let pressed = (event.flags.rawValue & Self.rightCommandFlagMask) != 0
                if pressed { handlePress(now) } else { handleRelease(now) }
            }
            return Unmanaged.passUnretained(event)   // never swallow a modifier

        case .keyDown:
            if keyCode == Self.escapeKeyCode, recordingActive {
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
        case .hybrid:
            if held >= Self.holdThreshold {
                endSession()                 // it was a hold → push-to-talk
            } else {
                handsFree = true             // brief tap → hands-free
                pressStartedSession = false
            }
        }
    }

    // MARK: Session transitions

    private func beginSession() {
        isSessionActive = true
        fire(onBegin)
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
        recordingActive = false
    }

    private func checkTapHealth() {
        guard let tap else { return }
        if !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
            resetPressed()
        }
    }

    /// Callbacks are deferred one main-loop turn so heavy work (audio, HUD) never
    /// runs inside the tap callback.
    private func fire(_ callback: (() -> Void)?) {
        guard let callback else { return }
        DispatchQueue.main.async { callback() }
    }
}
