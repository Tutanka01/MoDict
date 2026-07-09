import Foundation

/// Result of a single utterance transcription.
struct TranscriptionResult: Sendable {
    let text: String
    let confidence: Float          // 0…1
    let audioDuration: TimeInterval
    let processingTime: TimeInterval
}

/// Coarse progress for the one-time model download + compile on first launch.
struct ModelDownloadProgress: Sendable, Equatable {
    enum Phase: Sendable, Equatable { case checking, downloading, compiling, ready }
    let phase: Phase
    let fraction: Double           // 0…1 overall
}

/// A speech-to-text backend. Actor-bound so the model and its decoder state
/// stay isolated across the async transcription pipeline.
protocol TranscriptionEngine: Actor {
    nonisolated var id: String { get }
    nonisolated var displayName: String { get }
    /// Downloads (if needed) and loads the model. Reports progress on arbitrary threads.
    func prepare(progress: @escaping @Sendable (ModelDownloadProgress) -> Void) async throws
    var isReady: Bool { get async }
    /// languageHint: BCP-47-ish code like "en" / "fr", nil = automatic.
    func transcribe(_ samples: [Float], languageHint: String?) async throws -> TranscriptionResult
    func unload() async
}
