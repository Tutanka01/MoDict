import Testing
@testable import MoDict

struct DictationTraceTests {
    @Test
    func summaryCarriesStagesAndTheWaitAfterRelease() {
        var trace = DictationTrace(modelID: "parakeet-v3", pressedAt: 100)
        trace.mark(.begin, now: 100.04)
        trace.mark(.hold, now: 102)
        trace.mark(.tail, now: 102.2)
        trace.mark(.gate, now: 102.21)
        trace.mark(.engine, now: 102.27)
        trace.mark(.paste, now: 102.40)
        trace.noteAudio(seconds: 2.16)
        #expect(trace.summary(outcome: .pasted) ==
            "outcome=pasted model=parakeet-v3 audio_s=2.16 begin_ms=40 hold_ms=1960 tail_ms=200 gate_ms=10 engine_ms=60 paste_ms=130 release_to_end_ms=400")
    }

    @Test
    func aTapHasNoWaitAfterRelease() {
        var trace = DictationTrace(modelID: "m", pressedAt: 1)
        trace.mark(.begin, now: 1.04)
        #expect(trace.summary(outcome: .cancelled) == "outcome=cancelled model=m begin_ms=40")
    }

    /// The privacy rule is structural: no input of the type can hold text. This pins the
    /// fields, so adding a free-form one has to come through here.
    @Test
    func theLineOnlyHoldsKnownFields() {
        var trace = DictationTrace(modelID: "m", pressedAt: 1)
        trace.mark(.hold, now: 2)
        let keys = trace.summary(outcome: .empty).split(separator: " ").map { $0.split(separator: "=")[0] }
        #expect(Set(keys).isSubset(of: ["outcome", "model", "audio_s", "begin_ms", "hold_ms", "tail_ms", "gate_ms",
                                        "engine_ms", "paste_ms", "release_to_end_ms"]))
    }
}

struct TranscriptScoreTests {
    @Test
    func wordsSplitElisionsAndKeepAccents() {
        #expect(TranscriptScore.words("L'été, c'est-à-dire : 18h !") == ["l", "été", "c", "est", "à", "dire", "18h"])
    }

    @Test(arguments: [
        ("a b c", "a b c", 0), ("a x c", "a b c", 1), ("a c", "a b c", 1),
        ("a b c d", "a b c", 1), ("", "a b", 2), ("a b", "", 2), ("", "", 0),
    ])
    func editsCountWords(hypothesis: String, reference: String, expected: Int) {
        #expect(TranscriptScore.edits(TranscriptScore.words(hypothesis), TranscriptScore.words(reference)) == expected)
    }

    @Test
    func termsMatchWholeWordsOnly() {
        #expect(TranscriptScore.contains("Open Code", in: "avec open code, voilà"))
        #expect(!TranscriptScore.contains("Hex", in: "hexagone"))
        #expect(!TranscriptScore.contains("", in: "x"))
    }

    @Test
    func falseInsertionsIgnoreTermsTheReferenceHas() {
        #expect(TranscriptScore.falseInsertions(vocabulary: ["MoDict", "Hex"], text: "MoDict et Hex", expected: "MoDict et hexagone") == 1)
    }

    @Test
    func percentiles() {
        #expect(TranscriptScore.percentile([], 0.5) == nil)
        #expect(TranscriptScore.percentile([5], 0.95) == 5)
        #expect(TranscriptScore.percentile([1, 2, 3, 4], 0.5) == 3)
        #expect(TranscriptScore.percentile(Array(1...100), 0.95) == 96)
    }
}
