import Foundation
import MLX
import Qwen3ASR

/// Qwen3-ASR 1.7B, quantized to 4-bit and executed locally through MLX.
actor QwenAudioEngine: TranscriptionEngine {
    nonisolated let id = "qwen3-asr.1.7b-4bit"
    nonisolated let displayName = "Qwen3-ASR 1.7B"

    static let modelID = "aufklarer/Qwen3-ASR-1.7B-MLX-4bit"
    static let approximateDownloadBytes: Int64 = 2_230_000_000

    private var model: Qwen3ASRModel?
    /// The terms that fit the decoding prompt, and that prompt: nil without terms,
    /// which decodes exactly as with no vocabulary at all.
    private(set) var promptTerms: [String] = []
    private(set) var decodingContext: String?

    var isReady: Bool { model != nil }

    func setVocabularyHints(_ terms: [String]) {
        promptTerms = Self.promptTerms(from: terms)
        decodingContext = promptTerms.isEmpty ? nil : promptTerms.joined(separator: Self.termSeparator)
    }

    func prepare(progress: @escaping @Sendable (ModelDownloadProgress) -> Void) async throws {
        if model != nil {
            progress(ModelDownloadProgress(phase: .ready, fraction: 1))
            return
        }
        progress(ModelDownloadProgress(phase: .checking, fraction: 0))
        model = try await Qwen3ASRModel.fromPretrained(
            modelId: Self.modelID,
            cacheDir: Self.modelsDirectory,
            progressHandler: { fraction, _ in
                progress(ModelDownloadProgress(
                    phase: fraction < 0.8 ? .downloading : .compiling,
                    fraction: fraction
                ))
            }
        )
        progress(ModelDownloadProgress(phase: .ready, fraction: 1))
    }

    func transcribe(_ samples: [Float], languageHint: String?) async throws -> TranscriptionResult {
        guard let model else { throw QwenAudioEngineError.notReady }
        guard !samples.isEmpty else {
            return TranscriptionResult(text: "", confidence: 0, audioDuration: 0, processingTime: 0)
        }

        let startedAt = Date()
        let conditioned = AudioConditioner.condition(samples)
        let options = Qwen3DecodingOptions(
            language: Self.language(for: languageHint),
            context: decodingContext,
            repetitionPenalty: 1.15
        )
        var text = model.transcribe(audio: conditioned, sampleRate: 16_000, options: options)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           conditioned.count != samples.count {
            text = model.transcribe(audio: samples, sampleRate: 16_000, options: options)
        }
        if Self.isPromptEcho(text, terms: promptTerms) {
            text = ""
        }

        return TranscriptionResult(
            text: text,
            confidence: 1,
            audioDuration: TimeInterval(samples.count) / 16_000,
            processingTime: Date().timeIntervalSince(startedAt)
        )
    }

    nonisolated func startStreamingSession(
        languageHint: String?,
        onPartial: @escaping @Sendable (PartialTranscript) -> Void
    ) -> StreamingTranscriptionSession? {
        nil
    }

    func unload() async {
        model?.unload()
        model = nil
    }

    static var modelsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MoDict/Models/qwen3-asr-1.7b-4bit", isDirectory: true)
    }

    static func modelsExistOnDisk() -> Bool {
        modelsExist(at: modelsDirectory)
    }

    static func modelsExist(at directory: URL) -> Bool {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return false }
        let names = Set(files.map(\.lastPathComponent))
        let hasWeights = names.contains("model.safetensors")
            || (names.contains("model-00001-of-00002.safetensors")
                && names.contains("model-00002-of-00002.safetensors"))
        return hasWeights && names.contains("vocab.json")
    }

    static func deleteModels() throws {
        guard FileManager.default.fileExists(atPath: modelsDirectory.path) else { return }
        try FileManager.default.removeItem(at: modelsDirectory)
    }

    static func language(for hint: String?) -> String? {
        guard let hint, !hint.isEmpty, hint != "auto" else { return nil }
        return hint.lowercased()
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first
            .map(String.init)
    }

    // MARK: Vocabulary prompt

    private static let maximumPromptTerms = 64
    private static let maximumPromptCharacters = 1_000
    /// speech-swift places the context in the system turn, untouched, and encodes
    /// it as plain text, so a term cannot produce a control token.
    private static let termSeparator = ", "

    /// The unique, non-empty terms that fit the prompt, in order and whole. A term
    /// too long for what is left is skipped, so one long replacement in the list
    /// does not take every term after it out.
    static func promptTerms(from terms: [String]) -> [String] {
        var kept: [String] = []
        var seen = Set<String>()
        var characters = 0
        for raw in terms {
            guard kept.count < maximumPromptTerms else { break }
            let term = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !term.isEmpty, !seen.contains(term) else { continue }
            let added = term.count + (kept.isEmpty ? 0 : termSeparator.count)
            guard characters + added <= maximumPromptCharacters else { continue }
            kept.append(term)
            seen.insert(term)
            characters += added
        }
        return kept
    }

    /// True when the output is the whole prompt back, in order: given only silence
    /// or noise, a model can answer with its prompt. Anything less is kept, and so is
    /// a prompt under three terms, because saying a name or two is a legitimate use of
    /// the vocabulary and an output dropped here is words lost. Case, accents and
    /// punctuation are ignored.
    static func isPromptEcho(_ text: String, terms: [String]) -> Bool {
        let listed = terms.map(echoWords).filter { !$0.isEmpty }
        guard listed.count >= 3 else { return false }
        return echoWords(text) == Array(listed.joined())
    }

    private static func echoWords(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    /// Bundle guard rail, not a user code path: runs real MLX kernels inside a
    /// packaged app — device init, a reduction, and a 2×2 matmul that exercises
    /// the precompiled GEMM kernels from the shipped kernel library.
    /// `scripts/verify-bundle.sh` calls this from the built bundle; a missing or
    /// mismatched kernel library only shows up at runtime otherwise.
    static func runtimeSmokeTest() -> (reduction: Int, matmul: Int) {
        let reduction = Int((MLXArray([1, 2, 3] as [Float]) + 1).sum().item(Float.self))
        let matrix = MLXArray([1, 2, 3, 4] as [Float]).reshaped(2, 2)
        let identity = MLXArray([1, 0, 0, 1] as [Float]).reshaped(2, 2)
        let matmul = Int(matrix.matmul(identity).sum().item(Float.self))
        return (reduction, matmul)
    }
}

private enum QwenAudioEngineError: LocalizedError {
    case notReady

    var errorDescription: String? {
        "Qwen3-ASR is not loaded. Download or select the model in Settings."
    }
}
