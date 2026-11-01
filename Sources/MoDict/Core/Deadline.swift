import Foundation

/// Runs async work against a deadline, without waiting for the work to stop.
///
/// A task group cannot do this: it never returns before its children finish, so a
/// timeout child cannot release the caller from a synchronous Core ML or MLX call,
/// which ignores cancellation. Here the caller resumes on the first outcome, and
/// work that outlives it is cancelled and its late result dropped.
enum Deadline {
    static func run<T: Sendable>(
        seconds: TimeInterval,
        timeoutError: @escaping @Sendable () -> Error,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let race = Race<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.install(continuation)
                race.work = Task {
                    do {
                        // The caller may already be gone; `operation` may be an uncancellable decode.
                        try Task.checkCancellation()
                        race.finish(.success(try await operation()))
                    } catch {
                        race.finish(.failure(error))
                    }
                }
                race.timer = Task {
                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    race.finish(.failure(timeoutError()))
                }
            }
        } onCancel: {
            race.finish(.failure(CancellationError()))
        }
    }

    /// First outcome wins; it may arrive before the continuation is installed when
    /// the caller was already cancelled.
    private final class Race<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?
        private var outcome: Result<T, Error>?
        private var workTask: Task<Void, Never>?
        private var timerTask: Task<Void, Never>?

        var work: Task<Void, Never>? {
            get { locked { workTask } }
            set { adopt(newValue) { self.workTask = $0 } }
        }

        var timer: Task<Void, Never>? {
            get { locked { timerTask } }
            set { adopt(newValue) { self.timerTask = $0 } }
        }

        func install(_ continuation: CheckedContinuation<T, Error>) {
            let settled: Result<T, Error>? = locked {
                if let outcome { return outcome }
                self.continuation = continuation
                return nil
            }
            if let settled { continuation.resume(with: settled) }
        }

        func finish(_ result: Result<T, Error>) {
            let (waiting, tasks): (CheckedContinuation<T, Error>?, [Task<Void, Never>?]) = locked {
                guard outcome == nil else { return (nil, []) }
                outcome = result
                defer { continuation = nil }
                return (continuation, [workTask, timerTask])
            }
            tasks.forEach { $0?.cancel() }
            waiting?.resume(with: result)
        }

        /// A task handed over after the race settled has nothing left to do.
        private func adopt(_ task: Task<Void, Never>?, store: (Task<Void, Never>?) -> Void) {
            let settled: Bool = locked {
                store(task)
                return outcome != nil
            }
            if settled { task?.cancel() }
        }

        private func locked<R>(_ body: () -> R) -> R {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }
    }
}
