import Foundation
import Testing
@testable import MoDict

struct QwenVocabularyTests {

    // MARK: - Prompt terms

    @Test
    func keepsTermsInOrderWithoutBlanksOrRepeats() {
        #expect(QwenAudioEngine.promptTerms(from: ["MoDict", "", "  ", "Parakeet", "MoDict", " Qwen "])
            == ["MoDict", "Parakeet", "Qwen"])
    }

    @Test
    func aTermKeepsItsCasingAndStaysDistinct() {
        #expect(QwenAudioEngine.promptTerms(from: ["iOS", "IOS"]) == ["iOS", "IOS"])
    }

    @Test
    func aTermStaysOnOneLine() {
        #expect(QwenAudioEngine.promptTerms(from: ["Mohamad\n El\tAkhal"]) == ["Mohamad El Akhal"])
    }

    @Test
    func capsAtSixtyFourTerms() {
        let terms = (0..<100).map { "t\($0)" }
        #expect(QwenAudioEngine.promptTerms(from: terms) == Array(terms.prefix(64)))
    }

    @Test
    func capsAtOneThousandCharactersWithoutCuttingATerm() {
        // Twenty terms of 60 characters: 62 each with the separator.
        let terms = (0..<20).map { String(format: "%02d", $0) + String(repeating: "x", count: 58) }
        let kept = QwenAudioEngine.promptTerms(from: terms)

        #expect(kept == Array(terms.prefix(16)))
        #expect(kept.joined(separator: ", ").count <= 1_000)
    }

    @Test
    func exactlyOneThousandCharactersFit() {
        let first = String(repeating: "a", count: 998 - 1)
        // 997 + ", " + 1 = 1,000.
        #expect(QwenAudioEngine.promptTerms(from: [first, "b", "c"]) == [first, "b"])
    }

    @Test
    func aTermTooLongForThePromptDoesNotTakeTheOthersOut() {
        let long = String(repeating: "x", count: 1_500)
        #expect(QwenAudioEngine.promptTerms(from: [long, "MoDict", "Parakeet"]) == ["MoDict", "Parakeet"])
    }

    // MARK: - Engine state

    @Test
    func theContextIsCommaSeparatedTermsThroughTheProtocol() async {
        let qwen = QwenAudioEngine()
        let engine: any TranscriptionEngine = qwen
        await engine.setVocabularyHints(["MoDict", "Parakeet", "MoDict"])
        #expect(await qwen.decodingContext == "MoDict, Parakeet")
    }

    @Test
    func noVocabularyMeansNoContext() async {
        let qwen = QwenAudioEngine()
        #expect(await qwen.decodingContext == nil)

        await qwen.setVocabularyHints(["MoDict"])
        await qwen.setVocabularyHints([])
        #expect(await qwen.decodingContext == nil)

        await qwen.setVocabularyHints(["", "  "])
        #expect(await qwen.decodingContext == nil)
    }

    @Test
    func otherEnginesIgnoreHints() async {
        let engine: any TranscriptionEngine = FluidAudioEngine()
        await engine.setVocabularyHints(["MoDict"])
    }

    // MARK: - Echo

    private let terms = ["MoDict", "Parakeet", "Mohamad El Akhal"]

    @Test
    func theWholePromptIsAnEcho() {
        #expect(QwenAudioEngine.isPromptEcho("MoDict, Parakeet, Mohamad El Akhal", terms: terms))
    }

    @Test
    func anEchoNeedNotBeVerbatim() {
        #expect(QwenAudioEngine.isPromptEcho("modict. PARAKEET; mohamad el akhal", terms: terms))
        #expect(QwenAudioEngine.isPromptEcho("Élysée, Noël, Paris", terms: ["Elysee", "Noel", "Paris"]))
    }

    @Test
    func listedTermsDictatedOnTheirOwnAreKept() {
        #expect(!QwenAudioEngine.isPromptEcho("MoDict", terms: terms))
        #expect(!QwenAudioEngine.isPromptEcho("Mohamad El Akhal", terms: terms))
        #expect(!QwenAudioEngine.isPromptEcho("MoDict, Parakeet", terms: terms))
        #expect(!QwenAudioEngine.isPromptEcho("Parakeet MoDict Mohamad El Akhal", terms: terms))
    }

    @Test
    func aPromptUnderThreeTermsIsNeverAnEcho() {
        #expect(!QwenAudioEngine.isPromptEcho("MoDict", terms: ["MoDict"]))
        // Two rules that together spell a name someone says.
        #expect(!QwenAudioEngine.isPromptEcho("Mohamad El Akhal", terms: ["Mohamad", "El Akhal"]))
    }

    @Test
    func termsAmongOtherWordsAreDictation() {
        #expect(!QwenAudioEngine.isPromptEcho("MoDict et Parakeet", terms: terms))
        #expect(!QwenAudioEngine.isPromptEcho("J'utilise MoDict, Parakeet.", terms: terms))
        #expect(!QwenAudioEngine.isPromptEcho("MoDict, Parakeet, Mohamad", terms: terms))
    }

    @Test
    func aWordOnlyContainingATermIsNotThatTerm() {
        #expect(!QwenAudioEngine.isPromptEcho("MoDictionary Parakeets", terms: terms))
    }

    @Test
    func nothingIsAnEchoWithoutTermsOrWords() {
        #expect(!QwenAudioEngine.isPromptEcho("MoDict, Parakeet", terms: []))
        #expect(!QwenAudioEngine.isPromptEcho("", terms: terms))
        #expect(!QwenAudioEngine.isPromptEcho("...", terms: terms))
        #expect(!QwenAudioEngine.isPromptEcho("MoDict, Parakeet", terms: ["++", "--"]))
    }
}
