import CohereTranscribeASR
import Foundation
import MLX
import MLXNN

/// Cohere Transcribe 2B (03-2026), quantized to 5-bit and executed locally through MLX.
///
/// Why it is here (Docs/research/french-engine-comparison.md): on French talks with
/// human references it makes 7.6% word errors where Parakeet v3 makes 12.1%, and
/// 7.8% against 14.3% on dictations of 18 to 45 s. Its decoder prompt names the
/// language, so French cannot slide into English the way it does with Parakeet.
///
/// The weights take about 2 GB of memory, 2.8 GB while decoding, which a menu bar
/// app has no business holding all day. So they are loaded when a dictation starts, while the user is
/// still speaking, and released after `idleSeconds` without one: nothing at rest,
/// and a reload of about a second that the recording hides.
actor CohereAudioEngine: TranscriptionEngine {
    nonisolated let id = "cohere-transcribe.2b-5bit"
    nonisolated let displayName = "Cohere Transcribe"

    static let modelID = "aufklarer/Cohere-Transcribe-2B-MLX-5bit"
    static let approximateDownloadBytes: Int64 = 1_740_000_000

    /// The languages the model has a prompt for. It never detects one.
    static let supportedLanguageCodes: Set<String> = [
        "en", "fr", "de", "es", "it", "pt", "nl", "pl", "el", "ar", "ja", "zh", "vi", "ko",
    ]

    /// How long the weights stay in memory after the last use.
    static let idleSeconds: TimeInterval = 60
    /// MLX keeps freed buffers for reuse, without bound by default. Decoding one
    /// utterance at a time gains nothing from a large pool.
    private static let cacheLimitBytes = 256 << 20

    /// Whether audio holds a voice. The preview asks before its first decode:
    /// given a noisy room and no speech, the model writes words nobody said
    /// ("Merci.", a subtitling credit). The final pass has its own gate.
    private nonisolated let hasVoice: @Sendable ([Float]) async -> Bool

    init(hasVoice: @escaping @Sendable ([Float]) async -> Bool = { _ in true }) {
        self.hasVoice = hasVoice
    }

    private var model: CohereTranscribeModel?
    /// The files are on disk and dictation may start; the weights may not be loaded.
    private var isPrepared = false
    private var releaseTask: Task<Void, Never>?
    private var priorCacheLimit: Int?

    var isReady: Bool { isPrepared }
    /// Whether the weights are in memory right now (tests, benchmark).
    var isLoaded: Bool { model != nil }

    // MARK: Loading

    func prepare(progress: @escaping @Sendable (ModelDownloadProgress) -> Void) async throws {
        if isPrepared {
            progress(ModelDownloadProgress(phase: .ready, fraction: 1))
            return
        }
        progress(ModelDownloadProgress(phase: .checking, fraction: 0))
        if !Self.modelsExistOnDisk() {
            // A fresh download is loaded once, so a broken one fails here and
            // not at the first dictation.
            let downloaded = try await CohereTranscribeModel.fromPretrained(
                Self.modelID,
                cacheDir: Self.modelsDirectory,
                progressHandler: { fraction in
                    progress(ModelDownloadProgress(phase: .downloading, fraction: fraction * 0.97))
                }
            )
            progress(ModelDownloadProgress(phase: .compiling, fraction: 0.98))
            adopt(downloaded)
            scheduleRelease()
        }
        isPrepared = true
        progress(ModelDownloadProgress(phase: .ready, fraction: 1))
    }

    /// Starts loading the weights. Called at key-down, so the load runs while the
    /// user speaks instead of after they stop.
    func wake() async {
        guard isPrepared else { return }
        _ = try? loadedModel()
        scheduleRelease()
    }

    func unload() async {
        releaseTask?.cancel()
        releaseTask = nil
        release()
        isPrepared = false
    }

    /// Reads the weights from disk when they are not in memory. Never the network.
    private func loadedModel() throws -> CohereTranscribeModel {
        if let model { return model }
        let loaded = try CohereTranscribeModel.fromDirectory(Self.modelsDirectory)
        adopt(loaded)
        return loaded
    }

    private func adopt(_ loaded: CohereTranscribeModel) {
        if priorCacheLimit == nil {
            priorCacheLimit = Memory.cacheLimit
            Memory.cacheLimit = Self.cacheLimitBytes
        }
        model = loaded
    }

    private func scheduleRelease() {
        releaseTask?.cancel()
        releaseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.idleSeconds))
            guard !Task.isCancelled else { return }
            await self?.release()
        }
    }

    private func release() {
        guard let model else { return }
        // Dropping the reference is not enough: the weights leave memory only
        // once the module lets go of its arrays and MLX empties its buffer cache.
        model.apply(filter: Module.filterAll) { _ in MLXArray() }
        self.model = nil
        Memory.clearCache()
        if let priorCacheLimit {
            Memory.cacheLimit = priorCacheLimit
            self.priorCacheLimit = nil
        }
    }

    // MARK: Transcription

    func transcribe(_ samples: [Float], languageHint: String?) async throws -> TranscriptionResult {
        guard isPrepared else { throw CohereAudioEngineError.notReady }
        guard !samples.isEmpty else {
            return TranscriptionResult(text: "", confidence: 0, audioDuration: 0, processingTime: 0)
        }

        let startedAt = Date()
        let model = try loadedModel()
        defer { scheduleRelease() }
        let conditioned = AudioConditioner.condition(samples)
        let options = CohereTranscribeDecodingOptions(language: Self.language(for: languageHint))
        var text = model.transcribe(audio: conditioned, sampleRate: 16_000, options: options)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           conditioned.count != samples.count {
            text = model.transcribe(audio: samples, sampleRate: 16_000, options: options)
        }

        return TranscriptionResult(
            text: text,
            confidence: 1,
            audioDuration: TimeInterval(samples.count) / 16_000,
            processingTime: Date().timeIntervalSince(startedAt)
        )
    }

    // MARK: Live preview

    nonisolated func startStreamingSession(
        languageHint: String?,
        onPartial: @escaping @Sendable (PartialTranscript) -> Void
    ) -> StreamingTranscriptionSession? {
        CoherePreviewSession(
            engine: self, language: Self.language(for: languageHint),
            hasVoice: hasVoice, onPartial: onPartial)
    }

    /// One preview decode of the audio so far. nil when the weights cannot load;
    /// the preview then stays empty and the final pass reports the failure.
    fileprivate func previewText(for samples: [Float], language: String) -> String? {
        guard isPrepared, let model = try? loadedModel() else { return nil }
        defer { scheduleRelease() }
        return model.transcribe(
            audio: samples, sampleRate: 16_000,
            options: CohereTranscribeDecodingOptions(language: language))
    }

    // MARK: Static surface

    static var modelsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MoDict/Models/cohere-transcribe-2b-5bit", isDirectory: true)
    }

    static func modelsExistOnDisk() -> Bool {
        modelsExist(at: modelsDirectory)
    }

    /// The weights must also be whole: a download cut short leaves a file that is
    /// there and cannot load, and `prepare()` would call it ready.
    static func modelsExist(at directory: URL, minimumWeightBytes: Int64 = 1_700_000_000) -> Bool {
        let files = FileManager.default
        guard ["config.json", "tokenizer.model"].allSatisfy({
            files.fileExists(atPath: directory.appendingPathComponent($0).path)
        }) else { return false }
        let weights = directory.appendingPathComponent("model.safetensors").path
        let size = (try? files.attributesOfItem(atPath: weights)[.size] as? NSNumber)?.int64Value ?? -1
        return size >= minimumWeightBytes
    }

    static func deleteModels() throws {
        guard FileManager.default.fileExists(atPath: modelsDirectory.path) else { return }
        try FileManager.default.removeItem(at: modelsDirectory)
    }

    /// The language to prompt with. An explicit hint wins when the model knows
    /// it; otherwise the first of the Mac's languages it knows, then English.
    static func language(
        for hint: String?,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> String {
        let explicit = (hint?.isEmpty == false) && hint != "auto"
        let candidates = (explicit ? [hint!] : []) + preferredLanguages
        for candidate in candidates {
            if let primary = candidate.lowercased()
                .split(whereSeparator: { $0 == "-" || $0 == "_" })
                .first.map(String.init),
               supportedLanguageCodes.contains(primary) {
                return primary
            }
        }
        return "en"
    }
}

/// The live preview of one utterance: the audio so far, decoded again about once
/// a second by the model that will write the final text, so the words on screen
/// are the ones about to be pasted and not another model's guess.
///
/// Decoding everything again each time would slow down as the dictation grows.
/// Past `commitAfterSamples` of undecided audio, the part before a pause is
/// decoded one last time and kept; only what follows is decoded again.
private final class CoherePreviewSession: StreamingTranscriptionSession, @unchecked Sendable {

    private let lock = NSLock()
    private var samples: [Float] = []
    private var isClosed = false
    private var pump: Task<Void, Never>?

    init(engine: CohereAudioEngine,
         language: String,
         hasVoice: @escaping @Sendable ([Float]) async -> Bool,
         onPartial: @escaping @Sendable (PartialTranscript) -> Void) {
        pump = Task { [weak self] in
            var heardVoice = false
            var committedText = ""
            var committedSamples = 0
            var decodedSamples = 0
            var stabilizer = PreviewStabilizer()
            while !Task.isCancelled {
                // `self` is never held across a suspension: a session dropped
                // without `cancel()` must still be able to go away.
                guard let total = self?.sampleCount() else { return }
                guard total - decodedSamples >= CohereLivePreview.refreshSamples,
                      var pending = self?.audio(from: committedSamples),
                      CohereLivePreview.hasSound(pending)
                else {
                    try? await Task.sleep(for: .milliseconds(80))
                    continue
                }
                decodedSamples = total
                // Nothing is shown until a voice is heard; after that the audio
                // is known to hold speech and is not asked about again.
                if !heardVoice {
                    guard await hasVoice(pending) else { continue }
                    heardVoice = true
                }

                if pending.count > CohereLivePreview.commitAfterSamples,
                   let cut = CohereLivePreview.pause(in: pending),
                   let text = await engine.previewText(for: Array(pending[..<cut]), language: language) {
                    committedText = CohereLivePreview.join(committedText, text)
                    committedSamples += cut
                    pending = Array(pending[cut...])
                }
                guard let tail = await engine.previewText(for: pending, language: language) else { return }
                guard self?.sampleCount() != nil else { return }
                onPartial(stabilizer.partial(for: CohereLivePreview.join(committedText, tail)))
            }
        }
    }

    func feed(_ chunk: [Float]) {
        lock.lock()
        if !isClosed { samples.append(contentsOf: chunk) }
        lock.unlock()
    }

    /// The preview never writes the final text: that comes from one pass over the
    /// whole utterance.
    func finish() async throws -> TranscriptionResult {
        await cancel()
        throw CoherePreviewError.previewOnly
    }

    func cancel() async {
        let pump = close()
        pump?.cancel()
        // A decode in flight cannot be interrupted; wait for it, so the final
        // pass never competes with a preview for the model.
        await pump?.value
    }

    /// Synchronous so the lock stays out of async contexts.
    private func close() -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        isClosed = true
        samples = []
        return pump
    }

    /// nil once the session is closed.
    private func sampleCount() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return isClosed ? nil : samples.count
    }

    private func audio(from start: Int) -> [Float]? {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed, start < samples.count else { return nil }
        return Array(samples[start...])
    }
}

private enum CoherePreviewError: Error {
    case previewOnly
}

/// The arithmetic of the live preview. Pure, for tests.
enum CohereLivePreview {
    /// New audio needed before another decode.
    static let refreshSamples = 16_000
    /// Undecided audio beyond which the part before a pause is settled.
    static let commitAfterSamples = 18 * 16_000
    /// A pause is looked for after the first 6 s and before the last 3 s, so
    /// both sides keep enough context to decode well.
    private static let leadingSamples = 6 * 16_000
    private static let trailingSamples = 3 * 16_000
    private static let window = 1_600

    /// The middle of the quietest 100 ms away from both ends, or nil when the
    /// audio is too short to cut.
    static func pause(in samples: [Float]) -> Int? {
        let end = samples.count - trailingSamples
        guard end - leadingSamples >= window else { return nil }
        var best: Int?
        var quietest = Float.greatestFiniteMagnitude
        var start = leadingSamples
        while start + window <= end {
            var energy: Float = 0
            for index in start..<(start + window) { energy += samples[index] * samples[index] }
            if energy < quietest {
                quietest = energy
                best = start + window / 2
            }
            start += window / 2
        }
        return best
    }

    /// Whether any 20 ms of the audio rises above -50 dBFS. Digital silence and a
    /// quiet room are not worth a decode, and a model given nothing invents words.
    static func hasSound(_ samples: [Float]) -> Bool {
        let frame = 320
        let threshold: Float = 0.003 * 0.003 * Float(frame)
        var start = 0
        while start + frame <= samples.count {
            var energy: Float = 0
            for index in start..<(start + frame) { energy += samples[index] * samples[index] }
            if energy > threshold { return true }
            start += frame
        }
        return false
    }

    static func join(_ head: String, _ tail: String) -> String {
        let head = head.trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        if head.isEmpty { return tail }
        if tail.isEmpty { return head }
        return head + " " + tail
    }
}

/// Splits each preview into the words that survived two decodes in a row
/// (confirmed) and the ones still moving (volatile), so the HUD can show which
/// words are settled.
struct PreviewStabilizer {
    private var previous: [Substring] = []

    mutating func partial(for text: String) -> PartialTranscript {
        let words = text.split(separator: " ", omittingEmptySubsequences: true)
        var stable = 0
        while stable < min(words.count, previous.count), words[stable] == previous[stable] {
            stable += 1
        }
        previous = words
        return PartialTranscript(
            confirmedText: words[..<stable].joined(separator: " "),
            volatileText: words[stable...].joined(separator: " "))
    }
}

private enum CohereAudioEngineError: LocalizedError {
    case notReady

    var errorDescription: String? {
        "Cohere Transcribe is not ready. Download or select the model in Settings."
    }
}
