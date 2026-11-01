import Foundation
import Testing
@testable import MoDict

private typealias CaptureError = MicrophoneCapture.CaptureError

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    func mutate(_ body: (inout Value) -> Void) { lock.withLock { body(&stored) } }
}

/// Holds an `open` in progress, so a test can act while the engine is mid-start.
private final class OpenGate: Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)

    /// Called from inside the scripted `open`.
    func pass() {
        entered.signal()
        released.wait()
    }

    func waitUntilEntered() { entered.wait() }
    func release() { released.signal() }
}

/// Stands in for the hardware: records the lifecycle calls and lets a test deliver
/// buffers through any tap it was handed, retired ones included.
private final class FakeInputEngine: AudioInputEngine, @unchecked Sendable {
    enum Event: Equatable { case warmUp, open, close }

    private struct Tap {
        let onChunk: @Sendable ([Float]) -> Void
        let onConfigurationChange: @Sendable () -> Void
    }

    private let lock = NSLock()
    private var recorded: [Event] = []
    private var taps: [Tap] = []
    private var opened = false
    private var present = true
    /// Runs inside `open` with its 0-based index; blocks or throws to script it.
    private var script: (@Sendable (Int) throws -> Void)?

    var events: [Event] { lock.withLock { recorded } }
    var openCount: Int { events.filter { $0 == .open }.count }
    var isOpen: Bool { lock.withLock { opened } }

    func setHasInputDevice(_ value: Bool) { lock.withLock { present = value } }
    func scriptOpen(_ body: @escaping @Sendable (Int) throws -> Void) { lock.withLock { script = body } }

    func hasInputDevice() -> Bool { lock.withLock { present } }

    func warmUp() { lock.withLock { recorded.append(.warmUp) } }

    func open(_ source: CaptureSource,
              onChunk: @escaping @Sendable ([Float]) -> Void,
              onConfigurationChange: @escaping @Sendable () -> Void) throws {
        let (index, script) = lock.withLock {
            recorded.append(.open)
            taps.append(Tap(onChunk: onChunk, onConfigurationChange: onConfigurationChange))
            return (taps.count - 1, self.script)
        }
        try script?(index)
        lock.withLock { opened = true }
    }

    func close() {
        lock.withLock {
            recorded.append(.close)
            opened = false
        }
    }

    func deliver(_ chunk: [Float], toTap index: Int) {
        let tap = lock.withLock { taps[index] }
        tap.onChunk(chunk)
    }

    func changeConfiguration(ofTap index: Int) {
        let tap = lock.withLock { taps[index] }
        tap.onConfigurationChange()
    }
}

/// Drives the sequencing with a fake engine: every interleaving the controller can
/// produce must end with no tap left open and no audio crossing utterances.
@Suite(.timeLimit(.minutes(1)))
struct MicrophoneCaptureTests {

    private let engine = FakeInputEngine()
    private let queue = DispatchQueue(label: "test.capture")
    private let capture: MicrophoneCapture
    private let failures = Locked<[(error: CaptureError, utterance: UInt64)]>([])

    init() {
        capture = MicrophoneCapture(engine: engine, queue: queue)
        capture.onFatalInterruption = { [failures] error, utterance in
            failures.mutate { $0.append((error, utterance)) }
        }
    }

    private func start() throws {
        try capture.start(deviceUID: nil, avoidBluetooth: true)
    }

    /// Lets everything queued so far run.
    private func settle() {
        queue.sync {}
    }

    private func startOpened() throws {
        try start()
        settle()
    }

    /// Starts `finish` and returns once it is registered and its tail armed.
    private func beginFinish(tail: TimeInterval) async -> Task<[Float], Never> {
        let task = Task { [capture] in await capture.finish(tail: tail) }
        while !capture.isFinishing { await Task.yield() }
        settle()
        return task
    }

    // MARK: Start

    @Test
    func startReturnsWhileTheEngineIsStillOpening() throws {
        let gate = OpenGate()
        engine.scriptOpen { _ in gate.pass() }

        try start()   // would deadlock here if it opened synchronously
        gate.waitUntilEntered()
        gate.release()
        settle()

        #expect(engine.openCount == 1)
        #expect(engine.isOpen)
    }

    @Test
    func startThrowsRightAwayWithoutAnInputDevice() {
        engine.setHasInputDevice(false)

        #expect(throws: CaptureError.noInputDevice) { try start() }
        settle()

        #expect(engine.events.isEmpty)
        #expect(failures.value.isEmpty)
    }

    @Test
    func lateOpenFailureIsReportedAndLeavesNothingOpen() throws {
        engine.scriptOpen { _ in throw CaptureError.selectedDeviceUnavailable }

        try startOpened()

        #expect(failures.value.map(\.error) == [.selectedDeviceUnavailable])
        #expect(!engine.isOpen)
    }

    @Test
    func failureOfAnAbandonedStartIsDropped() throws {
        let gate = OpenGate()
        engine.scriptOpen { _ in
            gate.pass()
            throw CaptureError.engineStartFailed
        }

        try start()
        gate.waitUntilEntered()
        capture.cancel()
        gate.release()
        settle()

        #expect(failures.value.isEmpty)
        #expect(!engine.isOpen)
    }

    @Test
    func failureOfASupersededStartDoesNotTouchTheNewUtterance() throws {
        let gate = OpenGate()
        engine.scriptOpen { index in
            guard index == 0 else { return }
            gate.pass()
            throw CaptureError.engineStartFailed
        }

        try start()
        gate.waitUntilEntered()
        try start()
        gate.release()
        settle()

        #expect(failures.value.isEmpty)
        #expect(engine.openCount == 2)
        #expect(engine.isOpen)
    }

    @Test
    func aReportedFailureGoesStaleOnceANewUtteranceStarts() throws {
        engine.scriptOpen { index in
            if index == 0 { throw CaptureError.engineStartFailed }
        }

        try startOpened()
        let utterance = try #require(failures.value.first?.utterance)
        #expect(capture.isCurrent(utterance: utterance))

        try startOpened()
        #expect(!capture.isCurrent(utterance: utterance))
    }

    // MARK: Finish

    @Test
    func finishKeepsCapturingUntilABufferCoversTheTail() async throws {
        try startOpened()
        engine.deliver([1, 1], toTap: 0)

        let finishing = await beginFinish(tail: 0.3)
        engine.deliver([2], toTap: 0)
        #expect(capture.isFinishing)
        #expect(engine.isOpen)

        try await Task.sleep(for: .milliseconds(350))
        engine.deliver([3], toTap: 0)

        #expect(await finishing.value == [1, 1, 2, 3])
        settle()
        #expect(!engine.isOpen)
    }

    @Test
    func finishEndsWhenTheDeviceStopsDelivering() async throws {
        try startOpened()
        engine.deliver([1], toTap: 0)

        let clock = ContinuousClock()
        let begun = clock.now
        let samples = await capture.finish(tail: 0.02)

        #expect(samples == [1])
        #expect(clock.now - begun >= .milliseconds(20))
        settle()
        #expect(!engine.isOpen)
    }

    @Test
    func finishWithoutAudioStillGivesTheFirstBufferItsChance() async throws {
        try startOpened()

        let finishing = await beginFinish(tail: 0.05)
        engine.deliver([0.5], toTap: 0)   // landed just after the release
        try await Task.sleep(nanoseconds: 80_000_000)
        engine.deliver([0.25], toTap: 0)  // the one past the deadline ends the tail

        #expect(await finishing.value == [0.5, 0.25])
    }

    @Test
    func finishEndsWithoutAnyAudioAtTheBackstop() async throws {
        try startOpened()

        let clock = ContinuousClock()
        let begun = clock.now
        let samples = await capture.finish(tail: 0.01)

        #expect(samples.isEmpty)
        #expect(clock.now - begun < .seconds(5))
        settle()
        #expect(!engine.isOpen)
    }

    /// A device stuck inside `engine.start` holds the capture queue. The release must
    /// not depend on that queue, or the app would stay in "transcribing" for good.
    @Test
    func finishReturnsEvenWithTheCaptureQueueStuck() async throws {
        let gate = OpenGate()
        engine.scriptOpen { _ in gate.pass() }
        try start()
        gate.waitUntilEntered()

        let samples = await capture.finish(tail: 0.01)
        #expect(samples.isEmpty)

        gate.release()
        settle()
    }

    @Test
    func anOpenThatNeverDeliversIsReportedOnce() async throws {
        let reported = Locked(0)
        let quick = MicrophoneCapture(engine: engine, queue: queue, startTimeout: 0.02)
        quick.onFatalInterruption = { _, _ in reported.mutate { $0 += 1 } }
        try quick.start(deviceUID: nil, avoidBluetooth: true)
        settle()

        for _ in 0..<500 where reported.value == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await Task.sleep(nanoseconds: 100_000_000)   // room for a wrong second report
        #expect(reported.value == 1)
        quick.cancel()
    }

    @Test
    func anOpenThatDeliversIsNotReported() async throws {
        let reported = Locked(0)
        let quick = MicrophoneCapture(engine: engine, queue: queue, startTimeout: 0.05)
        quick.onFatalInterruption = { _, _ in reported.mutate { $0 += 1 } }
        try quick.start(deviceUID: nil, avoidBluetooth: true)
        settle()
        engine.deliver([0.1], toTap: 0)

        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(reported.value == 0)
        quick.cancel()
    }

    @Test
    func aFailedOpenDuringFinishIsAvailableToTheCaller() async throws {
        let gate = OpenGate()
        engine.scriptOpen { _ in
            gate.pass()
            throw CaptureError.engineStartFailed
        }
        try start()
        gate.waitUntilEntered()
        let finishing = Task { [capture] in await capture.finish(tail: 5) }
        while !capture.isFinishing { await Task.yield() }
        gate.release()

        #expect(await finishing.value.isEmpty)
        #expect(capture.takeCaptureFailure() == .engineStartFailed)
        #expect(capture.takeCaptureFailure() == nil)
    }

    @Test
    func finishRightAfterStartIsSafe() async throws {
        try start()
        let samples = await capture.finish(tail: 0.01)
        settle()

        #expect(samples.isEmpty)
        #expect(!engine.isOpen)
        #expect(failures.value.isEmpty)
    }

    @Test
    func finishWithNothingRecordingReturnsEmpty() async {
        #expect(await capture.finish(tail: 30).isEmpty)
    }

    @Test
    func openFailureDuringFinishEndsItWithoutAFatalReport() async throws {
        let gate = OpenGate()
        engine.scriptOpen { _ in
            gate.pass()
            throw CaptureError.engineStartFailed
        }

        try start()
        let finishing = Task { [capture] in await capture.finish(tail: 30) }
        while !capture.isFinishing { await Task.yield() }
        gate.release()

        #expect(await finishing.value.isEmpty)
        settle()
        #expect(failures.value.isEmpty)
        #expect(!engine.isOpen)
    }

    @Test
    func theNextUtteranceStartsEmptyAndIgnoresTheOldTap() async throws {
        try startOpened()
        engine.deliver([1], toTap: 0)
        #expect(await capture.finish(tail: 0) == [1])

        try startOpened()
        engine.deliver([9], toTap: 0)
        engine.deliver([2], toTap: 1)

        #expect(await capture.finish(tail: 0) == [2])
        settle()
        #expect(!engine.isOpen)
    }

    @Test
    func aStartDuringATailEndsTheOldFinishWithItsOwnAudio() async throws {
        try startOpened()
        engine.deliver([1], toTap: 0)
        let finishing = await beginFinish(tail: 30)

        try startOpened()

        #expect(await finishing.value == [1])
        engine.deliver([9], toTap: 0)
        engine.deliver([2], toTap: 1)
        #expect(engine.isOpen)
        #expect(await capture.finish(tail: 0) == [2])
    }

    // MARK: Cancel

    @Test
    func cancelRightAfterStartLeavesNothingOpen() throws {
        try start()
        capture.cancel()
        settle()

        #expect(!engine.isOpen)
    }

    @Test
    func cancelWhileOpeningClosesTheEngineAndDropsItsAudio() async throws {
        let gate = OpenGate()
        engine.scriptOpen { _ in gate.pass() }

        try start()
        gate.waitUntilEntered()
        capture.cancel()
        gate.release()
        settle()
        engine.deliver([9], toTap: 0)

        #expect(!engine.isOpen)
        #expect(await capture.finish(tail: 0).isEmpty)
    }

    @Test
    func cancelDuringATailReturnsEmptyAtOnce() async throws {
        try startOpened()
        engine.deliver([1], toTap: 0)
        let finishing = await beginFinish(tail: 30)

        capture.cancel()

        #expect(await finishing.value.isEmpty)
        settle()
        engine.deliver([9], toTap: 0)
        #expect(!engine.isOpen)

        try startOpened()
        engine.deliver([2], toTap: 1)
        #expect(await capture.finish(tail: 0) == [2])
    }

    @Test
    func cancelledAudioNeverReachesCallbacksOrTheNextUtterance() async throws {
        let chunks = Locked<[[Float]]>([])
        let levels = Locked<[Float]>([])
        capture.onChunk = { [chunks] chunk in chunks.mutate { $0.append(chunk) } }
        capture.onLevel = { [levels] level in levels.mutate { $0.append(level) } }

        try startOpened()
        engine.deliver([0.5, -0.5], toTap: 0)
        capture.cancel()
        settle()
        engine.deliver([9], toTap: 0)

        #expect(chunks.value == [[0.5, -0.5]])
        #expect(levels.value.count == 1)
        #expect(levels.value[0] > 0)

        try startOpened()
        engine.deliver([0], toTap: 1)
        #expect(levels.value.last == 0)
        #expect(await capture.finish(tail: 0) == [0])
    }

    // MARK: Configuration changes

    @Test
    func configurationChangeRebuildsAndKeepsTheSamples() async throws {
        try startOpened()
        engine.deliver([1], toTap: 0)

        engine.changeConfiguration(ofTap: 0)
        settle()

        #expect(engine.openCount == 2)
        #expect(engine.isOpen)
        engine.deliver([9], toTap: 0)
        engine.deliver([2], toTap: 1)
        #expect(await capture.finish(tail: 0) == [1, 2])
    }

    @Test
    func repeatedNotificationsFromOneEngineRebuildOnce() throws {
        try startOpened()

        engine.changeConfiguration(ofTap: 0)
        engine.changeConfiguration(ofTap: 0)
        settle()

        #expect(engine.openCount == 2)
    }

    @Test
    func failedRebuildReportsAndFinishStillReturnsTheSamples() async throws {
        engine.scriptOpen { index in
            if index == 1 { throw CaptureError.noInputDevice }
        }
        try startOpened()
        engine.deliver([1], toTap: 0)

        engine.changeConfiguration(ofTap: 0)
        settle()

        #expect(failures.value.map(\.error) == [.noInputDevice])
        #expect(!engine.isOpen)
        #expect(await capture.finish(tail: 30) == [1])
    }

    @Test
    func configurationChangeDuringATailEndsTheUtteranceWithItsSamples() async throws {
        try startOpened()
        engine.deliver([1], toTap: 0)
        let finishing = await beginFinish(tail: 30)

        engine.changeConfiguration(ofTap: 0)

        #expect(await finishing.value == [1])
        settle()
        #expect(engine.openCount == 1)
        #expect(!engine.isOpen)
        #expect(failures.value.isEmpty)
    }

    @Test
    func configurationChangeAfterCancelOrFinishDoesNotReopen() async throws {
        try startOpened()
        capture.cancel()
        engine.changeConfiguration(ofTap: 0)
        settle()
        #expect(engine.openCount == 1)

        try startOpened()
        engine.deliver([1], toTap: 1)
        _ = await capture.finish(tail: 0)
        engine.changeConfiguration(ofTap: 1)
        settle()
        #expect(engine.openCount == 2)
        #expect(!engine.isOpen)
    }

    // MARK: Warm-up

    @Test
    func warmUpRunsOnTheQueueInOrder() throws {
        capture.warmUp()
        try startOpened()

        #expect(engine.events.first == .warmUp)
        #expect(engine.events.last == .open)
    }
}
