import Foundation
import Testing
@testable import MoDict

/// Cohere Transcribe never detects a language and its preview decodes the same
/// audio again and again: the rules that decide what it is asked are pure, so
/// they are locked here without loading a model.
struct CohereEngineTests {

    @Test
    func anExplicitLanguageWinsWhenTheModelKnowsIt() {
        #expect(CohereAudioEngine.language(for: "fr", preferredLanguages: ["en-US"]) == "fr")
        #expect(CohereAudioEngine.language(for: "de_DE", preferredLanguages: ["fr-FR"]) == "de")
        #expect(CohereAudioEngine.language(for: "ja", preferredLanguages: ["fr-FR"]) == "ja")
    }

    @Test
    func automaticUsesTheMacsLanguageBecauseTheModelCannotDetectOne() {
        #expect(CohereAudioEngine.language(for: "auto", preferredLanguages: ["fr-FR", "en-US"]) == "fr")
        #expect(CohereAudioEngine.language(for: nil, preferredLanguages: ["fr-CA"]) == "fr")
        #expect(CohereAudioEngine.language(for: "", preferredLanguages: ["en-GB"]) == "en")
    }

    @Test
    func aLanguageTheModelLacksFallsBackToOneItCanWrite() {
        // Bulgarian is a Parakeet language, not a Cohere one.
        #expect(CohereAudioEngine.language(for: "bg", preferredLanguages: ["fr-FR"]) == "fr")
        #expect(CohereAudioEngine.language(for: "auto", preferredLanguages: ["bg-BG", "it-IT"]) == "it")
        #expect(CohereAudioEngine.language(for: "auto", preferredLanguages: ["bg-BG"]) == "en")
        #expect(CohereAudioEngine.language(for: "auto", preferredLanguages: []) == "en")
    }

    @Test
    func aModelFolderCountsOnlyWithWholeWeightsConfigAndTokenizer() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CohereEngineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(!CohereAudioEngine.modelsExist(at: directory, minimumWeightBytes: 4))
        for name in ["config.json", "tokenizer.model"] {
            try Data("x".utf8).write(to: directory.appendingPathComponent(name))
        }
        #expect(!CohereAudioEngine.modelsExist(at: directory, minimumWeightBytes: 4))
        // A download cut short: the file is there, and too small to be the weights.
        try Data("xx".utf8).write(to: directory.appendingPathComponent("model.safetensors"))
        #expect(!CohereAudioEngine.modelsExist(at: directory, minimumWeightBytes: 4))
        try Data("xxxx".utf8).write(to: directory.appendingPathComponent("model.safetensors"))
        #expect(CohereAudioEngine.modelsExist(at: directory, minimumWeightBytes: 4))
    }

    @Test
    func theRecommendedModelDependsOnTheMacsMemory() {
        #expect(SpeechModel.recommended(physicalMemory: 8 << 30) == .parakeetV3)
        #expect(SpeechModel.recommended(physicalMemory: 16 << 30) == .cohereTranscribe2B)
        #expect(SpeechModel.recommended(physicalMemory: 24 << 30) == .cohereTranscribe2B)
    }

    @Test
    func modelsThatShowTheirOwnWordsDoNotBorrowParakeet() {
        #expect(SpeechModel.cohereTranscribe2B.streamsOwnPreview)
        #expect(SpeechModel.parakeetV3.streamsOwnPreview)
        #expect(!SpeechModel.qwen3ASR1_7B.streamsOwnPreview)
        #expect(SpeechModel.cloudModels.allSatisfy { !$0.streamsOwnPreview })
    }

    // MARK: Live preview

    @Test
    func wordsThatSurviveTwoDecodesAreConfirmedAndTheRestStaysVolatile() {
        var stabilizer = PreviewStabilizer()

        let first = stabilizer.partial(for: "Bonjour à")
        #expect(first == PartialTranscript(confirmedText: "", volatileText: "Bonjour à"))

        let second = stabilizer.partial(for: "Bonjour à tous")
        #expect(second == PartialTranscript(confirmedText: "Bonjour à", volatileText: "tous"))

        // The model changed its mind about the second word: it is volatile again,
        // and so is everything after it.
        let third = stabilizer.partial(for: "Bonjour a tous les amis")
        #expect(third == PartialTranscript(confirmedText: "Bonjour", volatileText: "a tous les amis"))

        let empty = stabilizer.partial(for: "")
        #expect(empty.isEmpty)
    }

    @Test
    func aPauseIsFoundAwayFromBothEndsOfTheAudio() throws {
        // 20 s of tone with 300 ms of silence at 10 s, and one at 1 s that is too
        // early to cut on.
        var audio = (0..<(20 * 16_000)).map { Float(sin(Double($0) * 0.05)) * 0.3 }
        for index in (10 * 16_000)..<(10 * 16_000 + 4_800) { audio[index] = 0 }
        for index in 16_000..<(16_000 + 4_800) { audio[index] = 0 }

        let cut = try #require(CohereLivePreview.pause(in: audio))
        #expect(cut > 10 * 16_000 && cut < 10 * 16_000 + 4_800)
        // Too short to keep context on both sides.
        #expect(CohereLivePreview.pause(in: Array(audio[..<(8 * 16_000)])) == nil)
    }

    @Test
    func silenceIsNotWorthAPreviewDecode() {
        #expect(!CohereLivePreview.hasSound([Float](repeating: 0, count: 16_000)))
        #expect(!CohereLivePreview.hasSound([Float](repeating: 0.001, count: 16_000)))
        var quietRoomThenSpeech = [Float](repeating: 0.001, count: 16_000)
        quietRoomThenSpeech += (0..<3_200).map { Float(sin(Double($0) * 0.1)) * 0.05 }
        #expect(CohereLivePreview.hasSound(quietRoomThenSpeech))
    }

    @Test
    func settledAndPendingTextJoinWithOneSpace() {
        #expect(CohereLivePreview.join("", "Bonjour") == "Bonjour")
        #expect(CohereLivePreview.join("Bonjour. ", " Ça va") == "Bonjour. Ça va")
        #expect(CohereLivePreview.join("Bonjour.", "") == "Bonjour.")
    }
}
