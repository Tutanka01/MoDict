import Foundation
import Testing
@testable import MoDict

struct DeadlineTests {
    private struct Expired: Error {}

    /// The regression this type exists for: a call that ignores cancellation must
    /// not hold the caller past the deadline, as a task group would.
    @Test
    func aBlockingCallDoesNotHoldTheCallerPastTheDeadline() async {
        let started = Date()
        await #expect(throws: Expired.self) {
            try await Deadline.run(seconds: 0.05, timeoutError: { Expired() }) {
                usleep(1_000_000) // blocks the thread and ignores cancellation, like a Core ML call
                return 1
            }
        }
        #expect(Date().timeIntervalSince(started) < 0.8)
    }

    @Test
    func aFastResultWinsAndItsTimerIsCancelled() async throws {
        let value = try await Deadline.run(seconds: 5, timeoutError: { Expired() }) { 42 }
        #expect(value == 42)
    }

    @Test
    func anOperationErrorReachesTheCaller() async {
        struct Failed: Error {}
        await #expect(throws: Failed.self) {
            try await Deadline.run(seconds: 5, timeoutError: { Expired() }) { () -> Int in throw Failed() }
        }
    }

    @Test
    func cancellingTheCallerReleasesItAtOnceAndCancelsTheWork() async {
        let observed = Flag()
        let task = Task {
            try await Deadline.run(seconds: 30, timeoutError: { Expired() }) { () -> Int in
                do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { observed.set() }
                return 0
            }
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
        for _ in 0..<100 where !observed.isSet { try? await Task.sleep(nanoseconds: 10_000_000) }
        #expect(observed.isSet)
    }

    @Test
    func anAlreadyCancelledCallerNeverHangs() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await Deadline.run(seconds: 30, timeoutError: { Expired() }) { () -> Int in
                try await Task.sleep(nanoseconds: 30_000_000_000)
                return 0
            }
        }
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set() { lock.lock(); value = true; lock.unlock() }
    }
}
