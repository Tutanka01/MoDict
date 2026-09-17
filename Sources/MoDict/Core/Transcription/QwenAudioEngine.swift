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

    var isReady: Bool { model != nil }

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
            repetitionPenalty: 1.15
        )
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
