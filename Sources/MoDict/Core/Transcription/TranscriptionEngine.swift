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

/// Incremental transcript of an in-flight streaming session. `confirmedText` is
/// stable; `volatileText` is the trailing hypothesis and may still be revised.
struct PartialTranscript: Sendable, Equatable {
    let confirmedText: String
    let volatileText: String

    var isEmpty: Bool { confirmedText.isEmpty && volatileText.isEmpty }
}

/// Handle to one live streaming transcription session (one utterance).
protocol StreamingTranscriptionSession: AnyObject, Sendable {
    /// Feed one converted 16 kHz mono chunk. Synchronous and non-blocking, so it
    /// is safe on the audio thread; chunks fed from a single thread reach the
    /// recognizer in order. Chunks after `finish()`/`cancel()` are dropped.
    func feed(_ chunk: [Float])
    /// Stop accepting audio, drain everything fed so far, and return the final
    /// transcript. Throws when streaming never got off the ground — the caller
    /// falls back to the batch path.
    func finish() async throws -> TranscriptionResult
    /// Discard the session silently. Idempotent.
    func cancel() async
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
    /// Begin a live streaming session for one utterance, or nil when the engine
    /// cannot stream at all. Synchronous so the session can buffer audio from the
    /// very first microphone chunk; the actual recognizer spins up in the
    /// background and a failure there degrades to no partials (`finish()` then
    /// throws). `onPartial` is delivered on arbitrary threads. Starting a new
    /// session cancels a previous live one. Streaming always auto-detects the
    /// language — only the batch path honors a pinned language.
    nonisolated func startStreamingSession(
        onPartial: @escaping @Sendable (PartialTranscript) -> Void
    ) -> StreamingTranscriptionSession?
    func unload() async
}
