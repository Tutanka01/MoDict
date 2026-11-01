import CoreGraphics
import Foundation
import os

/// Runs the hotkey's event taps on their own thread and feeds `HotkeyGestureMachine`.
///
/// An active tap holds up every keystroke in the system until its callback returns,
/// so it must not share a run loop with anything that can stall: that is why this is
/// not the main thread. The callback only takes the lock, feeds the machine and hands
/// the actions to the main queue, in order, under that same lock.
///
/// Threads: `start`, `stop` and the `tapRunLoop`/`finished`/`activity` fields are for
/// the owner's thread (main). `InstalledTap`s and timers belong to the tap thread.
/// The machine is shared, behind `shared`.
///
/// The refcon handed to the taps is unretained. It stays valid because the thread's
/// closure retains `self` and the taps are invalidated on that thread, before it
/// exits; `stop` waits for that, so no callback can outlive this object.
final class HotkeyEventTaps: @unchecked Sendable {

    typealias Action = HotkeyGestureMachine.Action
    typealias Input = HotkeyGestureMachine.Input

    /// Both run on the main queue. Set once, before `start`.
    var deliver: (@Sendable ([Action]) -> Void)?
    var permissionLost: (@Sendable () -> Void)?

    private struct Shared {
        var machine = HotkeyGestureMachine()
        /// Read from main by `start` to answer repeat calls without a thread hop.
        var sessionTap: CFMachPort?
    }

    private struct InstalledTap {
        let port: CFMachPort
        let source: CFRunLoopSource
    }

    enum Kind {
        /// Active, because it must be able to swallow Esc.
        case session
        /// Listen-only key-downs, evidence of chords hidden from the session tap.
        case hid
    }

    private static let pollInterval: TimeInterval = 0.1
    private static let healthInterval: TimeInterval = 5.0

    private let shared = OSAllocatedUnfairLock(uncheckedState: Shared())
    private let createPort: (Kind, UnsafeMutableRawPointer) -> CFMachPort?
    private let permissionGranted: () -> Bool

    // Owner's thread.
    private var tapRunLoop: CFRunLoop?
    private var finished: DispatchSemaphore?
    private var activity: NSObjectProtocol?

    // Tap thread.
    private var sessionTap: InstalledTap?
    private var hidTap: InstalledTap?
    private var graceTimer: Timer?
    private var pollTimer: Timer?
    private var healthTimer: Timer?
    private var stopRequested = false

    /// The parameters let tests run the real thread and timers without a real tap.
    init(
        createPort: @escaping (Kind, UnsafeMutableRawPointer) -> CFMachPort? = HotkeyEventTaps.createEventTap,
        permissionGranted: @escaping () -> Bool = { CGPreflightListenEventAccess() }
    ) {
        self.createPort = createPort
        self.permissionGranted = permissionGranted
    }

    // MARK: Machine access

    var mode: HotkeyMonitor.Mode {
        get { shared.withLockUnchecked { $0.machine.mode } }
        set { shared.withLockUnchecked { $0.machine.mode = newValue } }
    }

    var key: DictationKey { shared.withLockUnchecked { $0.machine.key } }

    var isSessionActive: Bool { shared.withLockUnchecked { $0.machine.isSessionActive } }
    var lastPressedAt: TimeInterval { shared.withLockUnchecked { $0.machine.pressedAt } }

    func isLive(session: UInt64) -> Bool {
        shared.withLockUnchecked { $0.machine.isLive(session: session) }
    }

    /// Feeds an input from outside the tap thread. Timers are left alone on purpose:
    /// a stale grace timer is a no-op in the machine and the next press replaces it, a
    /// stale poll timer stops at its next tick. Reaching over from here could
    /// instead kill the timer of a press the tap thread has just seen.
    func feed(_ input: Input) {
        let now = ProcessInfo.processInfo.systemUptime
        shared.withLockUnchecked { state in
            let actions = state.machine.handle(input, now: now)
            dispatchToController(actions)
        }
    }

    // MARK: Lifecycle

    /// Cheap once running: `recheckPermissions` calls it on every app activation.
    func start() -> Bool {
        if tapRunLoop != nil {
            if let tap = shared.withLockUnchecked({ $0.sessionTap }), CGEvent.tapIsEnabled(tap: tap) {
                return true
            }
            // Repair rather than rebuild: a running session must survive this call.
            runOnTapThread { [self] in checkHealth() }
            return shared.withLockUnchecked { $0.sessionTap != nil }
        }

        let ready = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        var runLoop: CFRunLoop?
        // The thread's closure retains self until the taps are gone (see type comment).
        let thread = Thread { [self] in
            runTapThread(ready: { runLoop = $0; ready.signal() })
            finished.signal()
        }
        thread.name = "com.modict.hotkey-taps"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()

        guard let runLoop else {
            finished.wait()
            return false
        }
        tapRunLoop = runLoop
        self.finished = finished
        // App Nap would throttle the tap thread; idle sleep stays allowed.
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Listening for the dictation key"
        )
        return true
    }

    func stop() {
        if let tapRunLoop, let finished {
            // A block, not a bare CFRunLoopStop: a stop arriving before the loop has
            // entered would be lost, and this wait would never return.
            CFRunLoopPerformBlock(tapRunLoop, CFRunLoopMode.defaultMode.rawValue) { [self] in
                stopRequested = true
                CFRunLoopStop(CFRunLoopGetCurrent())
            }
            CFRunLoopWakeUp(tapRunLoop)
            finished.wait()
        }
        tapRunLoop = nil
        finished = nil
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
        activity = nil
        feed(.reset)
    }

    /// Blocks the owner's thread until `body` has run. The tap thread never waits on
    /// anybody, so this cannot deadlock.
    func runOnTapThread(_ body: @escaping () -> Void) {
        guard let tapRunLoop else { return }
        let done = DispatchSemaphore(value: 0)
        CFRunLoopPerformBlock(tapRunLoop, CFRunLoopMode.defaultMode.rawValue) {
            body()
            done.signal()
        }
        CFRunLoopWakeUp(tapRunLoop)
        done.wait()
    }

    // MARK: Tap thread

    private func runTapThread(ready: (CFRunLoop?) -> Void) {
        guard let session = install(.session) else {
            ready(nil)
            return
        }
        setSessionTap(session)
        // Without this one the app works as it would without the evidence.
        hidTap = install(.hid)
        healthTimer = scheduleTimer(every: Self.healthInterval) { [self] in checkHealth() }
        stopRequested = false
        ready(CFRunLoopGetCurrent())

        while !stopRequested {
            // The pool keeps whatever the callbacks autorelease from piling up for the
            // life of the thread, so return after each handled event to drain it.
            autoreleasepool { _ = CFRunLoopRunInMode(.defaultMode, 60, true) }
        }

        healthTimer?.invalidate()
        healthTimer = nil
        graceTimer?.invalidate()
        graceTimer = nil
        pollTimer?.invalidate()
        pollTimer = nil
        if let sessionTap { remove(sessionTap) }
        setSessionTap(nil)
        if let hidTap { remove(hidTap) }
        hidTap = nil
    }

    private func setSessionTap(_ tap: InstalledTap?) {
        sessionTap = tap
        shared.withLockUnchecked { $0.sessionTap = tap?.port }
    }

    private func install(_ kind: Kind) -> InstalledTap? {
        guard let port = createPort(kind, Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        else { return nil }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)
        CGEvent.tapEnable(tap: port, enable: true)
        return InstalledTap(port: port, source: source)
    }

    private static func createEventTap(_ kind: Kind, refcon: UnsafeMutableRawPointer) -> CFMachPort? {
        switch kind {
        case .session:
            return CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
                    | (CGEventMask(1) << CGEventType.keyDown.rawValue),
                callback: sessionTapCallback,
                userInfo: refcon
            )
        case .hid:
            return CGEvent.tapCreate(
                tap: .cghidEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: CGEventMask(1) << CGEventType.keyDown.rawValue,
                callback: hidTapCallback,
                userInfo: refcon
            )
        }
    }

    private func remove(_ tap: InstalledTap) {
        CGEvent.tapEnable(tap: tap.port, enable: false)
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), tap.source, .defaultMode)
        CFMachPortInvalidate(tap.port)
    }

    // MARK: Events

    func handleSessionEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let sessionTap { CGEvent.tapEnable(tap: sessionTap.port, enable: true) }
            reportInterruption()
        case .flagsChanged, .keyDown:
            guard !SyntheticEvents.isOwn(event) else { break }
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags.rawValue
            let actions = feedFromTapThread { machine in
                guard type == .flagsChanged else { return .keyDown(keyCode: keyCode) }
                // The device-dependent bit is specific to the chosen key: it clears
                // on release even if the left-hand sibling modifier is still held.
                guard keyCode == machine.key.keyCode else { return nil }
                return .triggerChanged(isDown: flags & machine.key.flagMask != 0)
            }
            if actions.contains(.swallowEvent) { return nil }   // the one and only swallowed event
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    func handleHIDEvent(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // Only evidence is lost meanwhile, so the session has nothing to reconcile.
            if let hidTap { CGEvent.tapEnable(tap: hidTap.port, enable: true) }
        case .keyDown:
            guard !SyntheticEvents.isOwn(event) else { return }
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            feedFromTapThread { _ in .hidKeyDown(keyCode: keyCode) }
        default:
            break
        }
    }

    @discardableResult
    private func feedFromTapThread(_ makeInput: (HotkeyGestureMachine) -> Input?) -> [Action] {
        let now = ProcessInfo.processInfo.systemUptime
        let (actions, held) = shared.withLockUnchecked { state -> ([Action], Bool) in
            guard let input = makeInput(state.machine) else { return ([], state.machine.isTriggerHeld) }
            let actions = state.machine.handle(input, now: now)
            dispatchToController(actions)
            return (actions, state.machine.isTriggerHeld)
        }
        for action in actions {
            switch action {
            case .scheduleBegin(let delay):
                graceTimer?.invalidate()
                graceTimer = scheduleTimer(after: delay) { [self] in
                    graceTimer = nil
                    feedFromTapThread { _ in .graceElapsed }
                }
            case .cancelScheduledBegin:
                graceTimer?.invalidate()
                graceTimer = nil
            default:
                break
            }
        }
        syncPolling(held: held)
        return actions
    }

    /// Runs under the lock, so actions from any thread reach the main queue in the
    /// order the machine decided them.
    private func dispatchToController(_ actions: [Action]) {
        let forController = actions.filter(\.reachesController)
        guard !forController.isEmpty, let deliver else { return }
        DispatchQueue.main.async { deliver(forController) }
    }

    // MARK: Physical state

    private func isPhysicallyDown(_ flagMask: UInt64) -> Bool {
        CGEventSource.flagsState(.hidSystemState).rawValue & flagMask != 0
    }

    private func syncPolling(held: Bool) {
        if held, pollTimer == nil {
            pollTimer = scheduleTimer(every: Self.pollInterval) { [self] in poll() }
        } else if !held, let timer = pollTimer {
            timer.invalidate()
            pollTimer = nil
        }
    }

    /// A release the tap never saw would otherwise leave the session recording, and
    /// the next press deduped against a key that is no longer down.
    private func poll() {
        let flagMask = shared.withLockUnchecked { $0.machine.key.flagMask }
        let isDown = isPhysicallyDown(flagMask)
        feedFromTapThread { _ in .physicalSample(isDown: isDown) }
    }

    private func reportInterruption() {
        let flagMask = shared.withLockUnchecked { $0.machine.key.flagMask }
        let isDown = isPhysicallyDown(flagMask)
        feedFromTapThread { _ in .tapInterrupted(physicallyDown: isDown) }
    }

    // MARK: Health

    /// Backstop against a silently disabled or dead tap: `tapDisabledBy…` is not
    /// guaranteed to arrive, and a dead port never delivers anything again.
    private func checkHealth() {
        guard permissionGranted() else {
            feedFromTapThread { _ in .reset }
            if let permissionLost { DispatchQueue.main.async { permissionLost() } }
            return
        }
        switch repair(sessionTap, kind: .session) {
        case .healthy:
            break
        case .reenabled(let tap), .recreated(let tap):
            setSessionTap(tap)
            reportInterruption()
        case .missing:
            setSessionTap(nil)
        }
        switch repair(hidTap, kind: .hid) {
        case .healthy:
            break
        case .reenabled(let tap), .recreated(let tap):
            hidTap = tap
        case .missing:
            hidTap = nil
        }
    }

    private enum Repair {
        case healthy
        case reenabled(InstalledTap)
        case recreated(InstalledTap)
        case missing
    }

    private func repair(_ tap: InstalledTap?, kind: Kind) -> Repair {
        if let tap {
            if CFMachPortIsValid(tap.port) {
                if CGEvent.tapIsEnabled(tap: tap.port) { return .healthy }
                CGEvent.tapEnable(tap: tap.port, enable: true)
                if CGEvent.tapIsEnabled(tap: tap.port) { return .reenabled(tap) }
            }
            remove(tap)
        }
        guard let fresh = install(kind) else { return .missing }
        return .recreated(fresh)
    }

    // MARK: Timers

    private func scheduleTimer(after delay: TimeInterval, _ body: @escaping () -> Void) -> Timer {
        let timer = Timer(timeInterval: delay, repeats: false) { _ in body() }
        RunLoop.current.add(timer, forMode: .default)
        return timer
    }

    private func scheduleTimer(every interval: TimeInterval, _ body: @escaping () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in body() }
        RunLoop.current.add(timer, forMode: .default)
        return timer
    }
}

// C function pointers cannot capture, so they recover the instance from the refcon.

private func sessionTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<HotkeyEventTaps>.fromOpaque(refcon).takeUnretainedValue()
        .handleSessionEvent(type: type, event: event)
}

private func hidTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let refcon {
        Unmanaged<HotkeyEventTaps>.fromOpaque(refcon).takeUnretainedValue()
            .handleHIDEvent(type: type, event: event)
    }
    return Unmanaged.passUnretained(event)
}
