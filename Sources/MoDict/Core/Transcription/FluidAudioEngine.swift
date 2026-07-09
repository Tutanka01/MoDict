import FluidAudio
import Foundation

/// Parakeet-TDT 0.6B **v3** (multilingual, on-device, ANE) via FluidAudio 0.15.5.
///
/// Signatures here were verified against the checked-out FluidAudio source, not
/// the README/GettingStarted docs — those describe a `configure(models:)` /
/// `transcribe(_:source:)` API that does not exist in the compiled package.
actor FluidAudioEngine: TranscriptionEngine {

    nonisolated let id = "fluidaudio.parakeet-v3"
    nonisolated let displayName = "Parakeet v3"

    private var manager: AsrManager?
    private var isModelReady = false

    /// Shared in-flight load, so two concurrent `prepare()` calls never download twice.
    private var prepareTask: Task<Void, Error>?
    /// Thread-safe fan-out for progress; each `prepare()` caller registers its handler here.
    private let progress = FluidAudioProgressBridge()

    init() {}

    var isReady: Bool { isModelReady }

    // MARK: Loading

    func prepare(progress handler: @escaping @Sendable (ModelDownloadProgress) -> Void) async throws {
        if isModelReady {
            handler(ModelDownloadProgress(phase: .ready, fraction: 1))
            return
        }

        progress.addHandler(handler)

        // Join an existing load rather than starting a second one.
        if let prepareTask {
            try await prepareTask.value
            handler(ModelDownloadProgress(phase: .ready, fraction: 1))
            return
        }

        let bridge = progress
        let task = Task<Void, Error> { [weak self] in
            let models = try await AsrModels.downloadAndLoad(version: .v3, progressHandler: { raw in
                bridge.emit(raw)
            })
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            await self?.adopt(manager)
        }
        prepareTask = task

        do {
            try await task.value
        } catch {
            prepareTask = nil
            progress.clear()
            throw error
        }
        prepareTask = nil
        progress.finish()
        progress.clear()
    }

    private func adopt(_ manager: AsrManager) {
        self.manager = manager
        self.isModelReady = true
    }

    func unload() async {
        await manager?.cleanup()
        manager = nil
        isModelReady = false
    }

    // MARK: Transcription

    func transcribe(_ samples: [Float], languageHint: String?) async throws -> TranscriptionResult {
        guard let manager else { throw FluidAudioEngineError.notReady }
        guard !samples.isEmpty else {
            return TranscriptionResult(text: "", confidence: 0, audioDuration: 0, processingTime: 0)
        }

        // Very short clips give the TDT decoder too little acoustic context to
        // flush its final tokens; a second of trailing silence fixes it and also
        // clears FluidAudio's ~300 ms minimum-length guard.
        var audio = samples
        if audio.count < Self.silencePadThreshold {
            audio.append(contentsOf: repeatElement(0, count: Self.silencePadSamples))
        }

        // A fresh decoder state per utterance — reusing one bleeds context
        // between unrelated dictations.
        var state = try TdtDecoderState()
        let result = try await manager.transcribe(
            audio,
            decoderState: &state,
            language: Self.language(for: languageHint)
        )

        return TranscriptionResult(
            text: result.text,
            confidence: result.confidence,
            audioDuration: TimeInterval(samples.count) / TimeInterval(Self.sampleRate),
            processingTime: result.processingTime
        )
    }

    // MARK: Static surface

    /// True if the v3 model files already exist on disk (cheap, for onboarding gating).
    static func modelsExistOnDisk() -> Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v3), version: .v3)
    }

    /// Directory where models are stored (for "Reveal in Finder").
    static var modelsDirectory: URL {
        AsrModels.defaultCacheDirectory(for: .v3)
    }

    /// ~482 MB: Encoder (int8) + Decoder + JointDecisionv3 + Preprocessor + vocab.
    static let approximateDownloadBytes: Int64 = 482_000_000

    /// The 25 European languages Parakeet v3 is trained on, sorted by English name.
    static let supportedLanguages: [(code: String, name: String)] = [
        ("bg", "Bulgarian"),
        ("hr", "Croatian"),
        ("cs", "Czech"),
        ("da", "Danish"),
        ("nl", "Dutch"),
        ("en", "English"),
        ("et", "Estonian"),
        ("fi", "Finnish"),
        ("fr", "French"),
        ("de", "German"),
        ("el", "Greek"),
        ("hu", "Hungarian"),
        ("it", "Italian"),
        ("lv", "Latvian"),
        ("lt", "Lithuanian"),
        ("mt", "Maltese"),
        ("pl", "Polish"),
        ("pt", "Portuguese"),
        ("ro", "Romanian"),
        ("ru", "Russian"),
        ("sk", "Slovak"),
        ("sl", "Slovenian"),
        ("es", "Spanish"),
        ("sv", "Swedish"),
        ("uk", "Ukrainian"),
    ]

    // MARK: Constants

    private static let sampleRate = 16_000
    /// Clips below one second get padded.
    private static let silencePadThreshold = 16_000
    /// One second of trailing silence.
    private static let silencePadSamples = 16_000

    /// Map a MoDict language hint onto FluidAudio's script-filter `Language`.
    /// Only the primary subtag matters ("fr-FR" → `.french`); unknown / "auto"
    /// yields nil, which lets the model auto-detect.
    // Note: unqualified `Language` — the FluidAudio module also exports a
    // `struct FluidAudio`, so `FluidAudio.Language` resolves into that struct.
    private static func language(for hint: String?) -> Language? {
        guard let hint, hint != "auto" else { return nil }
        let primary = hint.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? hint.lowercased()
        return Language(rawValue: primary)
    }
}

private enum FluidAudioEngineError: LocalizedError {
    case notReady

    var errorDescription: String? {
        switch self {
        case .notReady: return "The transcription model is not loaded yet."
        }
    }
}

/// Bridges FluidAudio's per-file `DownloadProgress` stream onto a single,
/// monotonic MoDict `ModelDownloadProgress`, and fans it out to every
/// registered `prepare()` handler. Called on arbitrary threads, hence the lock.
private final class FluidAudioProgressBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [@Sendable (ModelDownloadProgress) -> Void] = []
    private var lastFraction: Double = 0
    private var reachedCompiling = false

    func addHandler(_ handler: @escaping @Sendable (ModelDownloadProgress) -> Void) {
        lock.lock()
        handlers.append(handler)
        lock.unlock()
    }

    func emit(_ raw: DownloadProgress) {
        lock.lock()
        let mapped = map(raw)
        let sinks = handlers
        lock.unlock()
        for sink in sinks { sink(mapped) }
    }

    /// Terminal state, emitted once the manager has finished loading.
    func finish() {
        lock.lock()
        lastFraction = 1
        let sinks = handlers
        lock.unlock()
        let done = ModelDownloadProgress(phase: .ready, fraction: 1)
        for sink in sinks { sink(done) }
    }

    func clear() {
        lock.lock()
        handlers.removeAll()
        lastFraction = 0
        reachedCompiling = false
        lock.unlock()
    }

    /// Must be called with `lock` held.
    ///
    /// FluidAudio drives each internal model file through a download half
    /// (raw fraction 0…0.5) then a compile half (0.5…1.0), once per file, so the
    /// raw fraction is only meaningful within a phase — never globally. We fold
    /// it into a monotonic overall bar: the single large network download fills
    /// 0…0.9, the several quick ANE compilations creep 0.9…0.99, and the true
    /// 1.0 comes from `finish()`. A latch keeps the phase label from flapping
    /// back to "downloading" during the cached re-scans that follow the fetch.
    private func map(_ raw: DownloadProgress) -> ModelDownloadProgress {
        let phase: ModelDownloadProgress.Phase
        var candidate = lastFraction

        switch raw.phase {
        case .listing:
            phase = reachedCompiling ? .compiling : .checking
        case .downloading:
            phase = reachedCompiling ? .compiling : .downloading
            let f = min(max(raw.fractionCompleted, 0), 0.5) / 0.5   // 0…1 of the download half
            candidate = f * 0.9
        case .compiling:
            reachedCompiling = true
            phase = .compiling
            let f = min(max((raw.fractionCompleted - 0.5) / 0.5, 0), 1)
            candidate = 0.9 + f * 0.09
        }

        let overall = max(lastFraction, min(candidate, 0.99))
        lastFraction = overall
        return ModelDownloadProgress(phase: phase, fraction: overall)
    }
}
