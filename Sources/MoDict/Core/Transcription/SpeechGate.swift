import CoreML
import FluidAudio
import Foundation
import os

/// Keeps captures without speech away from the transcription engines.
///
/// Every engine invents text for audio with nothing in it, the start chime
/// included ("Yeah.", "C'est…"). That text would be pasted, and cloud models
/// would bill for it. Measured with the real Parakeet path: 58 of 208 holds
/// without speech produced text, 34 of 40 with the chime mixed in, while Silero's
/// highest probability stayed at or below 0.367 on those and reached 1.0 on all
/// 96 speech clips, speech attenuated by 30 dB included.
///
/// The gate fails open. It must never lose words because of its own failure, and
/// add no wait beyond its short budget: `evaluate` does not wait for the model. Until
/// the model is loaded it answers from the level check alone, and a detector that
/// errors or stalls counts as speech. The model ships in the app (Support/Models),
/// so nothing here touches the network.
actor SpeechGate {

    enum Reason: Equatable, Sendable {
        /// Below the level any speech reaches. Needs no model.
        case tooQuiet
        /// Loud enough, but the voice detector found no speech (chime, key clicks, room noise).
        case noVoiceDetected
    }

    enum Verdict: Equatable, Sendable {
        case speech
        case noSpeech(Reason)
    }

    /// True when 16 kHz mono samples contain speech.
    typealias VoiceDetector = @Sendable ([Float]) async throws -> Bool

    /// Not Hex's -50: 18 of 676 human French recordings (FLEURS) peak between -50
    /// and -53 dBFS, and Silero and both local engines still hear them. Noise
    /// between -50 and -60 is left to the detector, or reaches the engine as it
    /// always did while the detector is not loaded.
    static let silenceThresholdDBFS: Float = -60
    /// Not Silero's 0.5, which misses a whisper at -43 dBFS (Hex). The highest
    /// probability measured on captures without speech is 0.367.
    static let speechProbabilityThreshold: Float = 0.4
    /// The detector only discards captures up to this long. A discarded capture is
    /// gone for good, and long holds are where that hurts: nobody holds a key for
    /// this long by accident, while the invented text this gate exists to stop comes
    /// from short holds. The level check still applies at any length.
    static let longestDiscardableSeconds: TimeInterval = 10

    private static let sampleRate = 16_000
    private static let levelWindowSamples = 480 // 30 ms at 16 kHz
    /// Half a window, so a short sound straddling two windows keeps its level.
    private static let levelHopSamples = 240

    private static let logger = Logger(subsystem: "com.modict.app", category: "SpeechGate")

    private let loadDetector: @Sendable () async throws -> VoiceDetector
    private let detectionBudget: Duration
    private var detector: VoiceDetector?
    private var loadTask: Task<Void, Never>?
    private var pendingVerdicts: [UUID: CheckedContinuation<Verdict, Never>] = [:]

    static let modelName = "silero-vad-unified-256ms-v6.2.1"

    /// In `Contents/Resources`. Nil outside a bundle (`swift run`), where the gate
    /// works from the level check alone.
    static var bundledModelURL: URL? {
        Bundle.main.url(forResource: modelName, withExtension: "mlmodelc")
    }

    init(modelURL: URL? = SpeechGate.bundledModelURL) {
        self.init(detectionBudget: .milliseconds(1_500)) {
            guard let modelURL else { throw CocoaError(.fileNoSuchFile) }
            return try await Self.loadSilero(from: modelURL)
        }
    }

    /// `detectionBudget` bounds one verdict: Core ML predictions cannot be
    /// cancelled, and a stalled one must not hold the dictation up.
    init(detectionBudget: Duration,
         loadDetector: @escaping @Sendable () async throws -> VoiceDetector) {
        self.detectionBudget = detectionBudget
        self.loadDetector = loadDetector
    }

    // MARK: Loading

    /// Loads the model in the background. Returns at once and does nothing when the
    /// model is loaded or loading. A failure is logged, and only the next call tries again.
    func prepare() {
        guard detector == nil, loadTask == nil else { return }
        let load = loadDetector
        loadTask = Task.detached(priority: .utility) { [weak self] in
            do {
                let detector = try await load()
                await self?.finishLoading(detector)
            } catch {
                Self.logger.error("Voice detector unavailable: \(error.localizedDescription, privacy: .public)")
                await self?.finishLoading(nil)
            }
        }
    }

    private func finishLoading(_ detector: VoiceDetector?) {
        self.detector = detector
        loadTask = nil
    }

    /// Waits for a load in flight. For tests: `evaluate` never does this.
    func waitForLoad() async {
        await loadTask?.value
    }

    // MARK: Verdict

    /// Whether `samples` (16 kHz mono) are worth sending to an engine.
    func evaluate(_ samples: [Float]) async -> Verdict {
        if Self.isTooQuiet(samples) { return .noSpeech(.tooQuiet) }
        guard let detector,
              samples.count <= Int(Self.longestDiscardableSeconds) * Self.sampleRate else { return .speech }

        // Whichever settles first wins. A task group would wait for the detector
        // even after the timeout, which is the stall this has to survive.
        return await withCheckedContinuation { continuation in
            let id = UUID()
            pendingVerdicts[id] = continuation
            let timeout = Task {
                try await Task.sleep(for: detectionBudget)
                Self.logger.error("Voice detection exceeded its budget; treating the capture as speech")
                settle(id, with: .speech)
            }
            Task {
                let verdict: Verdict
                do {
                    verdict = try await detector(samples) ? .speech : .noSpeech(.noVoiceDetected)
                } catch {
                    Self.logger.error("Voice detection failed: \(error.localizedDescription, privacy: .public)")
                    verdict = .speech
                }
                timeout.cancel()
                settle(id, with: verdict)
            }
        }
    }

    private func settle(_ id: UUID, with verdict: Verdict) {
        pendingVerdicts.removeValue(forKey: id)?.resume(returning: verdict)
    }

    // MARK: Level

    static func isTooQuiet(_ samples: [Float]) -> Bool {
        loudestWindowDBFS(samples) < silenceThresholdDBFS
    }

    /// The RMS level of the loudest 30 ms window, with each window's DC offset
    /// removed: a constant offset is not sound. Negative infinity for digital
    /// silence and no samples, positive infinity for non-finite samples, so
    /// corrupt audio is never reported as quiet.
    static func loudestWindowDBFS(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return -.infinity }
        let size = min(levelWindowSamples, samples.count)
        var loudestVariance = 0.0
        var start = 0
        while true {
            var sum = 0.0
            var squares = 0.0
            for index in start..<(start + size) {
                let sample = Double(samples[index])
                sum += sample
                squares += sample * sample
            }
            let mean = sum / Double(size)
            let variance = squares / Double(size) - mean * mean
            guard variance.isFinite else { return .infinity }
            loudestVariance = max(loudestVariance, variance)

            let lastStart = samples.count - size
            if start == lastStart { break }
            start = min(start + levelHopSamples, lastStart)
        }
        return Float(10 * log10(loudestVariance))
    }

    // MARK: Silero

    private static func loadSilero(from url: URL) async throws -> VoiceDetector {
        let config = VadConfig(defaultThreshold: speechProbabilityThreshold)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = config.computeUnits
        let model = try MLModel(contentsOf: url, configuration: configuration)
        let manager = VadManager(config: config, vadModel: model)
        // The first prediction pays Core ML's one-time placement cost. Spend it
        // here rather than in the first dictation.
        _ = try await manager.process([Float](repeating: 0, count: VadManager.chunkSize))
        return { samples in try await containsVoice(samples, manager: manager) }
    }

    /// The same chunks and recurrent state as `VadManager.process(_:)`, which
    /// repeats the last sample to fill a chunk, so a clip shorter than 256 ms still
    /// gets one probability. Going chunk by chunk stops at the first speech, so
    /// the wait does not grow with the length of a dictation.
    private static func containsVoice(_ samples: [Float], manager: VadManager) async throws -> Bool {
        var state = await manager.makeStreamState()
        for start in stride(from: 0, to: samples.count, by: VadManager.chunkSize) {
            let end = min(start + VadManager.chunkSize, samples.count)
            let result = try await manager.processStreamingChunk(Array(samples[start..<end]), state: state)
            // Written this way so a NaN probability counts as speech.
            if !(result.probability < speechProbabilityThreshold) { return true }
            state = result.state
        }
        return false
    }
}
