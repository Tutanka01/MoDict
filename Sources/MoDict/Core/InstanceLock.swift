import Darwin
import Foundation

/// One running MoDict per user. A second copy would own a second event tap, so every
/// dictation would be recorded and pasted twice. The kernel drops the `flock` when
/// the process exits, however it exits, so a crash leaves nothing stale behind.
final class InstanceLock {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        close(descriptor)
    }

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MoDict/instance.lock")
    }

    /// Nil only when another live process holds the lock. Any other failure (an
    /// unwritable folder) returns a lock too: this guard must not stop the app.
    ///
    /// `patience` covers a relaunch right after a quit or `pkill`, whose process may
    /// not be gone yet: giving up at once would leave nothing running at all.
    static func acquire(at url: URL = defaultURL, patience: TimeInterval = 0) -> InstanceLock? {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return InstanceLock(descriptor: -1) }
        let giveUpAt = Date().addingTimeInterval(patience)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let heldElsewhere = errno == EWOULDBLOCK
            guard heldElsewhere, Date() < giveUpAt else {
                close(descriptor)
                return heldElsewhere ? nil : InstanceLock(descriptor: -1)
            }
            usleep(100_000)
        }
        return InstanceLock(descriptor: descriptor)
    }
}
