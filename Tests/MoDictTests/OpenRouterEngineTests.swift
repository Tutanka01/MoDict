import Foundation
import Testing
@testable import MoDict

struct OpenRouterEngineTests {
    @Test
    func wavContainsExpectedMonoPCMHeaderAndSamples() {
        let wav = OpenRouterEngine.wav([0, 1, -1])
        #expect(wav.count == 50)
        #expect(String(data: wav.prefix(4), encoding: .ascii) == "RIFF")
        #expect(String(data: wav[8..<12], encoding: .ascii) == "WAVE")
        #expect(wav[22] == 1 && wav[23] == 0) // mono
        #expect(wav[24] == 0x80 && wav[25] == 0x3e) // 16 kHz
        #expect(wav[34] == 16 && wav[35] == 0) // 16 bit
        #expect(Array(wav[44..<50]) == [0, 0, 0xff, 0x7f, 0x01, 0x80])
    }

    @Test
    func requestUsesDedicatedTranscriptionEndpointAndKeepsKeyOutOfBody() throws {
        for model in SpeechModel.cloudModels {
            let request = try OpenRouterEngine.request(
                model: model, samples: [0], languageHint: "fr-FR", key: "test-secret"
            )
            #expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/audio/transcriptions")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-secret")
            let body = try #require(request.httpBody)
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let audio = try #require(json["input_audio"] as? [String: String])
            #expect(json["model"] as? String == model.rawValue)
            #expect(json["language"] as? String == "fr")
            #expect(audio["format"] == "wav")
            #expect(Data(base64Encoded: try #require(audio["data"])) == OpenRouterEngine.wav([0]))
            #expect(!String(decoding: body, as: UTF8.self).contains("test-secret"))
        }
    }

    @Test
    func automaticLanguageOmitsHint() throws {
        let request = try OpenRouterEngine.request(
            model: .gptTranscribe, samples: [0], languageHint: "auto", key: "test-secret"
        )
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["language"] == nil)
    }

    @Test
    func decodesUsageWhenPresentAndToleratesItsAbsence() throws {
        let withUsage = Data(#"""
        {"text":"hello","usage":{"seconds":9.2,"input_tokens":83,"output_tokens":30,"cost":0.000508}}
        """#.utf8)
        let decoded = try JSONDecoder().decode(OpenRouterEngine.Response.self, from: withUsage)
        #expect(decoded.text == "hello")
        #expect(decoded.usage?.seconds == 9.2)
        #expect(decoded.usage?.inputTokens == 83)
        #expect(decoded.usage?.outputTokens == 30)
        let cost = try #require(decoded.usage?.cost)
        #expect(UsageFormat.cost(cost, locale: Locale(identifier: "en_US")) == "$0.0005")

        let withoutUsage = try JSONDecoder().decode(
            OpenRouterEngine.Response.self, from: Data(#"{"text":"hi"}"#.utf8))
        #expect(withoutUsage.usage == nil)
    }

    @Test
    func retriesOnlyTemporaryFailuresAndRespectsServerDelay() throws {
        func response(_ status: Int, retryAfter: String? = nil) throws -> HTTPURLResponse {
            try #require(HTTPURLResponse(
                url: URL(string: "https://openrouter.ai/api/v1/audio/transcriptions")!,
                statusCode: status,
                httpVersion: nil,
                headerFields: retryAfter.map { ["Retry-After": $0] }
            ))
        }

        #expect(OpenRouterEngine.retryDelay(for: try response(429), attempt: 0) == 2)
        #expect(OpenRouterEngine.retryDelay(for: try response(503), attempt: 2) == 8)
        #expect(OpenRouterEngine.retryDelay(for: try response(429, retryAfter: "6"), attempt: 0) == 6)
        #expect(OpenRouterEngine.retryDelay(
            for: try response(429, retryAfter: "Wed, 01 Jan 2025 00:00:06 GMT"),
            attempt: 0,
            now: Date(timeIntervalSince1970: 1_735_689_600)
        ) == 6)
        #expect(OpenRouterEngine.retryDelay(for: try response(429, retryAfter: "60"), attempt: 0) == nil)
        #expect(OpenRouterEngine.retryDelay(for: try response(401), attempt: 0) == nil)
        #expect(OpenRouterEngine.retryDelay(for: try response(500), attempt: 0) == nil)
        #expect(OpenRouterEngine.retryDelay(for: try response(429), attempt: 3) == nil)
    }
}
