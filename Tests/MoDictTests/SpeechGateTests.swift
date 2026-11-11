import CoreML
import FluidAudio
import Foundation
import Testing
@testable import MoDict

/// The level check, and the fail-open policy with a stand-in detector. Nothing
/// here needs the Silero model; `SpeechGateModelTests` uses the vendored one.
struct SpeechGateTests {

    @Test
    func theDetectorNeverDiscardsALongCapture() async {
        let gate = await preparedGate { _ in false }
        let loud = tone(amplitude: 0.1, count: 16_000 * 11)
        #expect(await gate.evaluate(loud) == .speech)
        #expect(await gate.evaluate(Array(loud.prefix(16_000 * 10))) == .noSpeech(.noVoiceDetected))
    }

    @Test
    func aLongSilentCaptureIsStillDiscarded() async {
        let gate = await preparedGate { _ in true }
        #expect(await gate.evaluate([Float](repeating: 0, count: 16_000 * 60)) == .noSpeech(.tooQuiet))
    }

    // MARK: - Level

    private func tone(amplitude: Float, count: Int) -> [Float] {
        (0..<count).map { amplitude * sin(2 * .pi * 220 * Float($0) / 16_000) }
    }

    @Test
    func emptyAndDigitalSilenceAreTooQuiet() {
        #expect(SpeechGate.isTooQuiet([]))
        #expect(SpeechGate.isTooQuiet([Float](repeating: 0, count: 16_000)))
    }

    @Test
    func aDCOffsetIsNotSound() {
        #expect(SpeechGate.isTooQuiet([Float](repeating: 0.2, count: 16_000)))
        // A -66 dBFS hum riding on the offset stays quiet too.
        #expect(SpeechGate.isTooQuiet(tone(amplitude: 0.000_7, count: 16_000).map { $0 + 0.2 }))
    }

    @Test
    func aDCOffsetDoesNotHideSpeech() {
        #expect(!SpeechGate.isTooQuiet(tone(amplitude: 0.1, count: 16_000).map { $0 + 0.2 }))
    }

    @Test
    func theThresholdSitsAtMinusSixtyDBFS() {
        // A sine's RMS is its amplitude over √2.
        let atMinus59 = tone(amplitude: pow(10, -59 / 20) * 2.0.squareRoot().float, count: 16_000)
        let atMinus61 = tone(amplitude: pow(10, -61 / 20) * 2.0.squareRoot().float, count: 16_000)
        #expect(abs(SpeechGate.loudestWindowDBFS(atMinus59) - -59) < 0.2)
        #expect(!SpeechGate.isTooQuiet(atMinus59))
        #expect(abs(SpeechGate.loudestWindowDBFS(atMinus61) - -61) < 0.2)
        #expect(SpeechGate.isTooQuiet(atMinus61))
    }

    @Test
    func theQuietestMeasuredHumanRecordingIsKept() {
        // FLEURS has decodable French whose loudest window is -53 dBFS.
        let samples = tone(amplitude: pow(10, -53 / 20) * 2.0.squareRoot().float, count: 16_000)
        #expect(!SpeechGate.isTooQuiet(samples))
    }

    @Test
    func aShortWhisperInSilenceIsKept() {
        // 100 ms at -43 dBFS RMS: the level the threshold exists to protect.
        let samples = [Float](repeating: 0, count: 8_000)
            + tone(amplitude: 0.01, count: 1_600)
            + [Float](repeating: 0, count: 6_400)
        #expect(abs(SpeechGate.loudestWindowDBFS(samples) - -43) < 0.5)
        #expect(!SpeechGate.isTooQuiet(samples))
    }

    @Test
    func soundAtTheVeryEndCounts() {
        // 5 ms past the last whole hop: the final window is anchored to the end.
        let samples = [Float](repeating: 0, count: 16_000) + tone(amplitude: 0.1, count: 80)
        #expect(!SpeechGate.isTooQuiet(samples))
    }

    @Test
    func aClipShorterThanOneWindowIsMeasuredWhole() {
        #expect(!SpeechGate.isTooQuiet(tone(amplitude: 0.1, count: 200)))
        #expect(SpeechGate.isTooQuiet(tone(amplitude: 0.000_7, count: 200)))
    }

    @Test
    func nonFiniteSamplesAreNeverCalledQuiet() {
        var samples = [Float](repeating: 0, count: 16_000)
        samples[8_000] = .nan
        #expect(!SpeechGate.isTooQuiet(samples))
        samples[8_000] = .infinity
        #expect(!SpeechGate.isTooQuiet(samples))
    }

    // MARK: - Verdicts

    private let loud = [Float](repeating: 0, count: 8_000)
        + (0..<8_000).map { 0.1 * sin(2 * .pi * 220 * Float($0) / 16_000) }

    private func gate(
        budget: Duration = .seconds(30),
        load: @escaping @Sendable () async throws -> SpeechGate.VoiceDetector
    ) -> SpeechGate {
        SpeechGate(detectionBudget: budget, loadDetector: load)
    }

    private func preparedGate(
        budget: Duration = .seconds(30),
        detector: @escaping SpeechGate.VoiceDetector
    ) async -> SpeechGate {
        let gate = gate(budget: budget) { detector }
        await gate.prepare()
        await gate.waitForLoad()
        return gate
    }

    @Test
    func theLevelCheckAnswersWithoutTheDetector() async {
        let calls = Counter()
        let gate = await preparedGate { _ in
            await calls.increment()
            return true
        }
        #expect(await gate.evaluate([Float](repeating: 0, count: 16_000)) == .noSpeech(.tooQuiet))
        #expect(await calls.value == 0)
    }

    @Test
    func theDetectorDecidesLoudCaptures() async {
        let voiced = await preparedGate { _ in true }
        #expect(await voiced.evaluate(loud) == .speech)
        let unvoiced = await preparedGate { _ in false }
        #expect(await unvoiced.evaluate(loud) == .noSpeech(.noVoiceDetected))
    }

    @Test
    func withoutPrepareOnlyTheLevelCheckRuns() async {
        let gate = gate { Issue.record("must not load"); return { _ in false } }
        #expect(await gate.evaluate(loud) == .speech)
        #expect(await gate.evaluate([]) == .noSpeech(.tooQuiet))
    }

    @Test
    func evaluateDoesNotWaitForALoadInFlight() async {
        let (release, releaseLoad) = AsyncStream<Void>.makeStream()
        let gate = gate {
            for await _ in release { break }
            return { _ in false }
        }
        await gate.prepare()

        // Would deadlock here if `evaluate` waited for the download.
        #expect(await gate.evaluate(loud) == .speech)
        #expect(await gate.evaluate([]) == .noSpeech(.tooQuiet))

        releaseLoad.yield()
        await gate.waitForLoad()
        #expect(await gate.evaluate(loud) == .noSpeech(.noVoiceDetected))
    }

    @Test
    func aFailedLoadFailsOpenAndRetriesOnlyAtTheNextPrepare() async {
        let attempts = Counter()
        let gate = gate {
            let attempt = await attempts.increment()
            if attempt == 1 { throw TestFailure() }
            return { _ in false }
        }

        await gate.prepare()
        await gate.waitForLoad()
        #expect(await attempts.value == 1)
        #expect(await gate.evaluate(loud) == .speech)
        #expect(await attempts.value == 1)

        await gate.prepare()
        await gate.waitForLoad()
        #expect(await attempts.value == 2)
        #expect(await gate.evaluate(loud) == .noSpeech(.noVoiceDetected))
    }

    @Test
    func prepareLoadsOnce() async {
        let attempts = Counter()
        let (release, releaseLoad) = AsyncStream<Void>.makeStream()
        let gate = gate {
            await attempts.increment()
            for await _ in release { break }
            return { _ in true }
        }

        await gate.prepare()
        await gate.prepare()
        releaseLoad.yield()
        await gate.waitForLoad()
        await gate.prepare()
        await gate.waitForLoad()

        #expect(await attempts.value == 1)
    }

    @Test
    func aDetectorErrorCountsAsSpeech() async {
        let gate = await preparedGate { _ in throw TestFailure() }
        #expect(await gate.evaluate(loud) == .speech)
    }

    @Test
    func aStalledDetectorCountsAsSpeechOnceTheBudgetIsSpent() async {
        let (never, keepAlive) = AsyncStream<Void>.makeStream()
        let gate = await preparedGate(budget: .milliseconds(20)) { _ in
            for await _ in never {}
            return false
        }
        #expect(await gate.evaluate(loud) == .speech)
        keepAlive.finish()
    }

    @Test
    func aLateDetectorAnswerIsIgnored() async {
        let (release, releaseDetector) = AsyncStream<Void>.makeStream()
        let finished = Counter()
        let gate = await preparedGate(budget: .milliseconds(20)) { _ in
            for await _ in release { break }
            await finished.increment()
            return false
        }
        #expect(await gate.evaluate(loud) == .speech)

        releaseDetector.yield()
        while await finished.value == 0 { await Task.yield() }
        // Resuming the first verdict twice would crash; the gate keeps answering.
        #expect(await gate.evaluate([]) == .noSpeech(.tooQuiet))
    }
}

/// The real Silero model, the copy the app ships, through the real gate.
struct SpeechGateModelTests {

    private func loadedGate() async throws -> SpeechGate {
        let gate = SpeechGate(modelURL: SileroLocation.modelURL)
        await gate.prepare()
        await gate.waitForLoad()
        // A probe no detector would call speech: `.speech` here means it failed to load.
        let chime = (0..<16_000).map { Float(0.2 * sin(2 * .pi * 880 * Double($0) / 16_000)) }
        try #require(await gate.evaluate(chime) == .noSpeech(.noVoiceDetected))
        return gate
    }

    private func spoken(_ text: String, voice: String) throws -> [Float] {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("modict-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("speech.aiff")

        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", voice, "-o", file.path, text]
        // Bounded: on a CI runner `say` has stopped answering, and an unbounded
        // wait then holds a thread, and with it the whole run, until the job's limit.
        let exited = DispatchSemaphore(value: 0)
        say.terminationHandler = { _ in exited.signal() }
        try say.run()
        guard exited.wait(timeout: .now() + Self.synthesisLimit) == .success else {
            say.terminate()
            throw SynthesisTimedOut()
        }
        try #require(say.terminationStatus == 0)
        return try AudioConverter().resampleAudioFile(file)
    }

    private static let synthesisLimit: TimeInterval = 60
    private struct SynthesisTimedOut: Error {}

    @Test
    func noiseAndToneAreNotSpeech() async throws {
        let gate = try await loadedGate()
        var seed: UInt32 = 0x2545_f491
        let noise: [Float] = (0..<32_000).map { _ in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return (Float(seed) / Float(UInt32.max) * 2 - 1) * 0.03
        }
        #expect(await gate.evaluate(noise) == .noSpeech(.noVoiceDetected))
    }

    @Test
    func speechPassesEvenAttenuatedByThirtyDecibels() async throws {
        let gate = try await loadedGate()
        let speech = try spoken("Envoie le compte rendu à toute l'équipe avant vendredi.", voice: "Thomas")
        #expect(await gate.evaluate(speech) == .speech)
        let attenuation = Float(pow(10, -30.0 / 20))
        #expect(await gate.evaluate(speech.map { $0 * attenuation }) == .speech)
    }

    @Test
    func aShortWordPassesInAClipBelowOneChunk() async throws {
        let gate = try await loadedGate()
        let word = try spoken("Oui.", voice: "Thomas")
        // From the first sound on, so the cut really holds the word.
        let bounds = try #require(AudioConditioner.speechBounds(in: word))
        let start = bounds.lowerBound
        let below = Array(word[start..<min(start + VadManager.chunkSize - 1, word.count)])
        #expect(await gate.evaluate(below) == .speech)
        let hold = Array(word[start..<min(start + 5_600, word.count)]) // the shortest kept hold, 0.35 s
        #expect(await gate.evaluate(hold) == .speech)
    }

    @Test
    func chunkByChunkMatchesTheBatchAPI() async throws {
        let manager = VadManager(
            config: VadConfig(defaultThreshold: SpeechGate.speechProbabilityThreshold),
            vadModel: try MLModel(contentsOf: SileroLocation.modelURL))
        let speech = try spoken("On se retrouve devant la gare à dix-huit heures.", voice: "Thomas")

        let batch = try await manager.process(speech).map(\.probability)
        var state = await manager.makeStreamState()
        var streamed: [Float] = []
        for start in stride(from: 0, to: speech.count, by: VadManager.chunkSize) {
            let chunk = Array(speech[start..<min(start + VadManager.chunkSize, speech.count)])
            let result = try await manager.processStreamingChunk(chunk, state: state)
            streamed.append(result.probability)
            state = result.state
        }
        #expect(batch == streamed)
    }
}

private enum SileroLocation {
    static let modelURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Support/Models/\(SpeechGate.modelName).mlmodelc")
}

private struct TestFailure: Error {}

private actor Counter {
    private(set) var value = 0

    @discardableResult
    func increment() -> Int {
        value += 1
        return value
    }
}

private extension Double {
    var float: Float { Float(self) }
}
