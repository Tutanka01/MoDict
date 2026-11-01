import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac from idle-sleeping while a dictation is live: a long hands-free
/// dictation produces no keyboard or mouse input, so the idle timer would otherwise
/// put the machine to sleep mid-sentence. Closing the lid still sleeps, and the hold
/// lapses by itself, so a forgotten hands-free session cannot keep a Mac awake all night.
final class IdleSleepGuard: @unchecked Sendable {
    /// Assertion calls are IPC to powerd, so they stay off the main actor. A serial
    /// queue keeps hold and release in order.
    private let queue = DispatchQueue(label: "com.modict.idle-sleep", qos: .utility)
    private let acquire: @Sendable () -> IOPMAssertionID?
    private let release: @Sendable (IOPMAssertionID) -> Void
    private var assertion: IOPMAssertionID?

    init(acquire: @escaping @Sendable () -> IOPMAssertionID? = IdleSleepGuard.createAssertion,
         release: @escaping @Sendable (IOPMAssertionID) -> Void = { IOPMAssertionRelease($0) }) {
        self.acquire = acquire
        self.release = release
    }

    /// Idempotent: repeating the same state does nothing.
    func setActive(_ active: Bool) {
        queue.async { [self] in
            if active, assertion == nil {
                assertion = acquire()
            } else if !active, let held = assertion {
                release(held)
                assertion = nil
            }
        }
    }

    /// Waits for earlier `setActive` calls; for tests.
    func drain() {
        queue.sync {}
    }

    private static let longestHoldSeconds = 15 * 60

    private static let createAssertion: @Sendable () -> IOPMAssertionID? = {
        var id = IOPMAssertionID(kIOPMNullAssertionID)
        let status = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoIdleSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "MoDict dictation in progress" as CFString,
            &id)
        guard status == kIOReturnSuccess else { return nil }
        IOPMAssertionSetProperty(id, kIOPMAssertionTimeoutKey as CFString, longestHoldSeconds as CFNumber)
        IOPMAssertionSetProperty(id, kIOPMAssertionTimeoutActionKey as CFString,
                                 kIOPMAssertionTimeoutActionRelease as CFString)
        return id
    }
}
