import AVFoundation
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
    /// Retained so streaming sessions can share the already-loaded models — a
    /// `SlidingWindowAsrManager.loadModels(_:)` with these is reference
    /// assignment only, no second download or compile.
    private var models: AsrModels?
    private var isModelReady = false
    /// The single live streaming session; starting a new one cancels it.
    private var activeStreamingSession: FluidStreamingSession?

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
            await self?.adopt(manager, models: models)
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
        await warmUp()
        progress.finish()
        progress.clear()
    }

    private func adopt(_ manager: AsrManager, models: AsrModels) {
        self.manager = manager
        self.models = models
        self.isModelReady = true
    }

    /// The first inference pays CoreML's one-time ANE placement cost, so the first
    /// real dictation of a session would feel slow. Spend it here on a throwaway
    /// second of silence before reporting ready. Best-effort — a failure must not
    /// fail `prepare`; the model is already usable.
    private func warmUp() async {
        guard let manager else { return }
        progress.reportWarmUp()
        do {
            var state = try TdtDecoderState()
            _ = try await manager.transcribe(
                [Float](repeating: 0, count: Self.warmUpSampleCount),
                decoderState: &state,
                language: nil
            )
        } catch {
            NSLog("MoDict: ANE warm-up failed: \(error)")
        }
    }

    func unload() async {
        if let session = activeStreamingSession {
            activeStreamingSession = nil
            await session.cancel()
        }
        await manager?.cleanup()
        manager = nil
        models = nil
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

    // MARK: Streaming

    nonisolated func startStreamingSession(
        onPartial: @escaping @Sendable (PartialTranscript) -> Void
    ) -> StreamingTranscriptionSession? {
        // Synchronous on purpose: the session buffers chunks from the instant it
        // exists, so no leading audio is lost while the recognizer spins up on
        // the actor. Readiness is checked there; a failure degrades to
        // no-partials and `finish()` throwing into the batch fallback.
        FluidStreamingSession(engine: self, onPartial: onPartial)
    }

    /// Called from a session's startup task: hands it a loaded sliding-window
    /// manager and makes it the single live session (cancelling the previous).
    fileprivate func attachStreamingManager(
        for session: FluidStreamingSession
    ) async throws -> SlidingWindowAsrManager {
        guard let models else { throw FluidAudioEngineError.notReady }
        if let previous = activeStreamingSession, previous !== session {
            await previous.cancel()
        }
        activeStreamingSession = session
        // A fresh manager per utterance: its input AsyncStream is created once in
        // init and permanently finished by finish()/cancel(), so an instance can
        // never accept audio for a second utterance (reset() does not revive it).
        let manager = SlidingWindowAsrManager(config: Self.streamingConfig)
        try await manager.loadModels(models)
        return manager
    }

    /// Sliding-window layout tuned for dictation. `chunkSeconds` is the real
    /// update-cadence knob — the presets' `hypothesisChunkSeconds` is never read
    /// by the 0.15.5 processing loop, and their 11 s chunk + 2 s right context
    /// would show nothing until 13 s of audio. 1 s chunks give ~1 update/s with
    /// the first partial after ~2 s of speech; left 10 + chunk 1 + right 1 = 12 s
    /// stays inside the model's fixed 15 s input (`ASRConstants.maxModelSamples`).
    fileprivate static let streamingConfig = SlidingWindowAsrConfig(
        chunkSeconds: 1.0,
        hypothesisChunkSeconds: 1.0,
        leftContextSeconds: 10.0,
        rightContextSeconds: 1.0,
        minContextForConfirmation: 10.0,
        confirmationThreshold: 0.85
    )

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
    /// One second of silence fed to the ANE to warm it after load.
    private static let warmUpSampleCount = 16_000

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

/// One live pseudo-streaming utterance over FluidAudio's `SlidingWindowAsrManager`.
///
/// Ordering, end to end: the audio thread yields `[Float]` chunks synchronously
/// into a local `AsyncStream` (buffered from the instant the session exists, so
/// nothing recorded is lost while the recognizer spins up). One pump task
/// consumes that stream sequentially and forwards each chunk — wrapped in an
/// `AVAudioPCMBuffer` — to the actor-isolated `streamAudio`. A single ordered
/// consumer preserves chunk order; a `Task {}` per chunk would not.
private final class FluidStreamingSession: StreamingTranscriptionSession, @unchecked Sendable {

    private let onPartial: @Sendable (PartialTranscript) -> Void
    private let chunkContinuation: AsyncStream<[Float]>.Continuation

    /// Startup + pump. Resolves to nil when streaming never got off the ground
    /// (logged; dictation degrades to the batch path with no partials). Completes
    /// only once the chunk stream is finished by `finish()`/`cancel()`.
    private var running: Task<(manager: SlidingWindowAsrManager, updates: Task<Void, Never>)?, Never>!

    private let lock = NSLock()
    private var isClosed = false
    private var fedSampleCount = 0
    private var lastConfidence: Float = 1

    init(engine: FluidAudioEngine, onPartial: @escaping @Sendable (PartialTranscript) -> Void) {
        self.onPartial = onPartial
        let (chunks, continuation) = AsyncStream<[Float]>.makeStream()
        self.chunkContinuation = continuation

        running = Task { [weak self] in
            let manager: SlidingWindowAsrManager
            let updateStream: AsyncStream<SlidingWindowTranscriptionUpdate>
            do {
                guard let self else { return nil }
                manager = try await engine.attachStreamingManager(for: self)
                // The updates getter installs the continuation — read it before
                // any audio flows or early updates would be dropped.
                updateStream = await manager.transcriptionUpdates
                try await manager.startStreaming(source: .microphone)
            } catch {
                NSLog("MoDict: streaming session failed to start: \(error)")
                return nil
            }

            let updates = Task { [weak self] in
                var assembler = StreamingTranscriptAssembler()
                for await update in updateStream {
                    guard let self else { break }
                    // Assemble overlapping hypotheses into one cumulative preview.
                    // This is presentation-only; the final paste still comes from
                    // the independent full-utterance batch transcription.
                    let cumulativeText = assembler.ingest(update.text)
                    let partial = PartialTranscript(
                        confirmedText: cumulativeText,
                        volatileText: ""
                    )
                    self.note(confidence: update.confidence)
                    self.onPartial(partial)
                }
            }

            for await chunk in chunks {
                guard let buffer = Self.makeBuffer(chunk) else { continue }
                await manager.streamAudio(buffer)
            }
            return (manager, updates)
        }
    }

    func feed(_ chunk: [Float]) {
        lock.lock()
        let open = !isClosed
        if open { fedSampleCount += chunk.count }
        lock.unlock()
        guard open, !chunk.isEmpty else { return }
        chunkContinuation.yield(chunk)
    }

    func finish() async throws -> TranscriptionResult {
        let finishStarted = Date()
        let (alreadyClosed, sampleCount) = close()
        guard !alreadyClosed else { throw FluidAudioEngineError.streamingUnavailable }

        chunkContinuation.finish()
        guard let (manager, updates) = await running.value else {
            throw FluidAudioEngineError.streamingUnavailable
        }
        // Cancel the update consumer only after the drain, so late partials still
        // flow while the final windows are processed.
        defer { updates.cancel() }
        let text = try await manager.finish()

        return TranscriptionResult(
            text: text,
            confidence: currentConfidence(),
            audioDuration: TimeInterval(sampleCount) / 16_000,
            processingTime: Date().timeIntervalSince(finishStarted)
        )
    }

    func cancel() async {
        _ = close()
        chunkContinuation.finish()
        guard let (manager, updates) = await running.value else { return }
        updates.cancel()
        // Without this the manager's recognizer task would wait on its input
        // stream forever, keeping the whole session graph alive.
        await manager.cancel()
    }

    /// Marks the session closed; returns whether it already was and the samples
    /// fed so far. Synchronous so the lock stays out of async contexts.
    private func close() -> (alreadyClosed: Bool, sampleCount: Int) {
        lock.lock()
        defer { lock.unlock() }
        let already = isClosed
        isClosed = true
        return (already, fedSampleCount)
    }

    private func currentConfidence() -> Float {
        lock.lock()
        defer { lock.unlock() }
        return lastConfidence
    }

    private func note(confidence: Float) {
        lock.lock()
        lastConfidence = confidence
        lock.unlock()
    }

    /// The mic already delivers 16 kHz mono Float32, so FluidAudio's converter
    /// takes its fast path and just copies the samples back out.
    private static let streamFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    private static func makeBuffer(_ chunk: [Float]) -> AVAudioPCMBuffer? {
        guard !chunk.isEmpty,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: streamFormat,
                frameCapacity: AVAudioFrameCount(chunk.count)
              ),
              let channel = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(chunk.count)
        chunk.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: chunk.count)
        }
        return buffer
    }
}

private enum FluidAudioEngineError: LocalizedError {
    case notReady
    case streamingUnavailable

    var errorDescription: String? {
        switch self {
        case .notReady: return "The transcription model is not loaded yet."
        case .streamingUnavailable: return "Live transcription was not available for this recording."
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

    /// Holds the bar at compiling/0.99 during the ANE warm-up (after load, before
    /// `finish()`), so the UI never regresses and the phase stays "compiling".
    func reportWarmUp() {
        lock.lock()
        lastFraction = max(lastFraction, 0.99)
        let sinks = handlers
        lock.unlock()
        let warming = ModelDownloadProgress(phase: .compiling, fraction: 0.99)
        for sink in sinks { sink(warming) }
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
