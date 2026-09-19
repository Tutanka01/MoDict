import Foundation

/// Batch transcription through OpenRouter. Audio exists only in memory and is sent
/// to the fixed HTTPS endpoint after the user ends a dictation.
actor OpenRouterEngine: TranscriptionEngine {
    nonisolated let id: String
    nonisolated let displayName: String

    private let model: SpeechModel
    private let session: URLSession
    private var ready = false

    init(model: SpeechModel) {
        precondition(model.isCloud)
        self.model = model
        id = model.rawValue
        displayName = model.displayName
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    var isReady: Bool { ready }

    func prepare(progress: @escaping @Sendable (ModelDownloadProgress) -> Void) async throws {
        ready = try OpenRouterKeychain.read() != nil
        guard ready else { throw OpenRouterError.missingKey }
        progress(ModelDownloadProgress(phase: .ready, fraction: 1))
    }

    func unload() async { ready = false }

    nonisolated func startStreamingSession(
        languageHint: String?,
        onPartial: @escaping @Sendable (PartialTranscript) -> Void
    ) -> StreamingTranscriptionSession? { nil }

    func transcribe(_ samples: [Float], languageHint: String?) async throws -> TranscriptionResult {
        guard ready, let key = try OpenRouterKeychain.read() else { throw OpenRouterError.missingKey }
        guard !samples.isEmpty else {
            return TranscriptionResult(text: "", confidence: 0, audioDuration: 0, processingTime: 0)
        }
        guard samples.count <= 16_000 * 600 else { throw OpenRouterError.clipTooLong }

        let startedAt = Date()
        let request = try Self.request(
            model: model, samples: samples, languageHint: languageHint, key: key
        )
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OpenRouterError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw OpenRouterError.httpStatus(http.statusCode)
        }
        guard data.count < 1_000_000,
              let text = try? JSONDecoder().decode(Response.self, from: data).text else {
            throw OpenRouterError.invalidResponse
        }
        return TranscriptionResult(
            text: text,
            confidence: 1,
            audioDuration: Double(samples.count) / 16_000,
            processingTime: Date().timeIntervalSince(startedAt)
        )
    }

    static func request(model: SpeechModel, samples: [Float], languageHint: String?, key: String) throws -> URLRequest {
        var payload: [String: Any] = [
            "model": model.rawValue,
            "input_audio": ["data": wav(samples).base64EncodedString(), "format": "wav"]
        ]
        if let language = languageHint?.split(separator: "-").first,
           language.count == 2, language != "auto" {
            payload["language"] = String(language).lowercased()
        }
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    /// 16 kHz mono Float → 16-bit little-endian PCM WAV (accepted by all three models).
    static func wav(_ samples: [Float]) -> Data {
        let pcm = samples.map { sample -> Int16 in
            let value = sample.isFinite ? min(1, max(-1, sample)) : 0
            return Int16((value * 32_767).rounded()).littleEndian
        }
        var data = Data(capacity: 44 + pcm.count * 2)
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8)
        append(UInt32(36 + pcm.count * 2))
        data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(16_000))
        append(UInt32(32_000))
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: "data".utf8)
        append(UInt32(pcm.count * 2))
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    private struct Response: Decodable { let text: String }
}

/// Do not forward the bearer token or audio to a different host on HTTP redirect.
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum OpenRouterError: LocalizedError {
    case missingKey
    case clipTooLong
    case httpStatus(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingKey: "Add an OpenRouter API key in Settings → Model."
        case .clipTooLong: "Cloud dictation is limited to 10 minutes. Try a shorter recording."
        case .httpStatus(401), .httpStatus(403): "OpenRouter rejected the API key. Check it in Settings → Model."
        case .httpStatus(402): "OpenRouter credits are insufficient. Check your account balance."
        case .httpStatus(404): "This model is unavailable on OpenRouter right now. Try another model."
        case .httpStatus(413): "The recording is too large for OpenRouter. Try a shorter one."
        case .httpStatus(429): "OpenRouter rate limit reached. Try again shortly."
        case .httpStatus: "OpenRouter could not transcribe this recording. Try again."
        case .invalidResponse: "OpenRouter returned an invalid transcription response."
        }
    }
}
