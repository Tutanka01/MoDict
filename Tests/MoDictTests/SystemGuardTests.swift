import Foundation
import IOKit.pwr_mgt
import Testing
@testable import MoDict

struct InstanceLockTests {
    private func temporaryLockURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("modict-lock-\(UUID().uuidString)/instance.lock")
    }

    @Test
    func aSecondOwnerIsRefusedUntilTheFirstGoesAway() {
        let url = temporaryLockURL()
        var first = InstanceLock.acquire(at: url)
        #expect(first != nil)
        #expect(InstanceLock.acquire(at: url) == nil)
        first = nil
        #expect(InstanceLock.acquire(at: url) != nil)
    }

    @Test
    func patienceWaitsForAnOwnerThatIsGoingAway() async {
        let url = temporaryLockURL()
        let held = LockBox(InstanceLock.acquire(at: url))
        Task.detached {
            try? await Task.sleep(nanoseconds: 150_000_000)
            held.release()
        }
        #expect(InstanceLock.acquire(at: url, patience: 5) != nil)
    }

    private final class LockBox: @unchecked Sendable {
        private var lock: InstanceLock?
        init(_ lock: InstanceLock?) { self.lock = lock }
        func release() { lock = nil }
    }

    @Test
    func anUnwritableLocationDoesNotStopTheApp() {
        #expect(InstanceLock.acquire(at: URL(fileURLWithPath: "/dev/null/instance.lock")) != nil)
    }
}

struct IdleSleepGuardTests {
    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [String] = []
        var all: [String] { lock.lock(); defer { lock.unlock() }; return events }
        func add(_ event: String) { lock.lock(); events.append(event); lock.unlock() }
    }

    @Test
    func holdsOnceAndReleasesOnce() {
        let log = Log()
        let guardian = IdleSleepGuard(
            acquire: { log.add("acquire"); return 7 },
            release: { log.add("release \($0)") })
        guardian.setActive(true)
        guardian.setActive(true)
        guardian.setActive(false)
        guardian.setActive(false)
        guardian.drain()
        #expect(log.all == ["acquire", "release 7"])
    }

    @Test
    func aRefusedAssertionIsNeverReleased() {
        let log = Log()
        let guardian = IdleSleepGuard(acquire: { nil }, release: { _ in log.add("release") })
        guardian.setActive(true)
        guardian.setActive(false)
        guardian.drain()
        #expect(log.all.isEmpty)
    }
}
