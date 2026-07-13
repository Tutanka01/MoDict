import Testing
@testable import MoDict

struct StreamingTranscriptAssemblerTests {
    @Test
    func cumulativeHypothesisGrowsWithoutRepeatingItsPrefix() {
        var assembler = StreamingTranscriptAssembler()

        _ = assembler.ingest("Je suis en train de parler et le texte avance")
        let result = assembler.ingest(
            "Je suis en train de parler et le texte avance doucement dans la fenêtre"
        )

        #expect(result == "Je suis en train de parler et le texte avance doucement dans la fenêtre")
    }

    @Test
    func rollingWindowKeepsOlderHistoryAndAppendsOnlyItsNewTail() {
        var assembler = StreamingTranscriptAssembler()

        _ = assembler.ingest(
            "Au début de cette démonstration nous allons vérifier que le texte reste bien stable"
        )
        let result = assembler.ingest(
            "nous allons vérifier que le texte reste bien stable pendant que la personne continue de parler"
        )

        #expect(result == "Au début de cette démonstration nous allons vérifier que le texte reste bien stable pendant que la personne continue de parler")
    }

    @Test
    func recentTailCanBeCorrectedWithoutErasingStableWords() {
        var assembler = StreamingTranscriptAssembler()

        _ = assembler.ingest(
            "Cette ancienne partie doit rester stable mais la fin est vraiment bizarre aujourd'hui"
        )
        let result = assembler.ingest(
            "Cette ancienne partie doit rester stable mais la fin devient maintenant beaucoup plus naturelle"
        )

        #expect(result == "Cette ancienne partie doit rester stable mais la fin devient maintenant beaucoup plus naturelle")
    }

    @Test
    func shortEarlyHypothesesMergeNaturally() {
        var assembler = StreamingTranscriptAssembler()

        #expect(assembler.ingest("Bonjour") == "Bonjour")
        #expect(assembler.ingest("Bonjour tout le monde") == "Bonjour tout le monde")
    }

    @Test
    func unrelatedEarlyFragmentDoesNotEraseTheFirstWords() {
        var assembler = StreamingTranscriptAssembler()

        _ = assembler.ingest("Une première phrase")
        let result = assembler.ingest("qui continue ensuite")

        #expect(result == "Une première phrase qui continue ensuite")
    }

    // With 1 s chunks the manager mostly emits short fragments of freshly
    // decoded words. These regressions cover the two ways the old merge lost
    // text: splicing on a one-word false anchor ("et", "de"…) and a fallback
    // that replaced the last twelve words instead of appending.

    @Test
    func shortFragmentSharingACommonWordNeverSplicesTheSentence() {
        var assembler = StreamingTranscriptAssembler()

        _ = assembler.ingest("et là il y a des phrases où c'est coupé au milieu")
        let result = assembler.ingest("et ensuite")

        #expect(result == "et là il y a des phrases où c'est coupé au milieu et ensuite")
    }

    @Test
    func freshChunkFragmentsAppendWithoutEatingHistory() {
        var assembler = StreamingTranscriptAssembler()

        _ = assembler.ingest("Salut comment ça va donc là actuellement je suis en train de tester")
        _ = assembler.ingest("le nouveau système")
        let result = assembler.ingest("et en vrai je pense")

        #expect(result == "Salut comment ça va donc là actuellement je suis en train de tester le nouveau système et en vrai je pense")
    }

    @Test
    func boundaryEchoIsDeduplicatedOnce() {
        var assembler = StreamingTranscriptAssembler()

        _ = assembler.ingest("nous allons continuer la démonstration")
        let result = assembler.ingest("la démonstration sans jamais répéter")

        #expect(result == "nous allons continuer la démonstration sans jamais répéter")
    }

    @Test
    func discontinuityNeverShrinksTheDocument() {
        var assembler = StreamingTranscriptAssembler()

        let history = assembler.ingest(
            "Ce long passage déjà dicté doit rester intégralement visible dans l'aperçu même quand le décodeur repart de zéro"
        )
        let result = assembler.ingest("quelque chose de complètement nouveau")

        #expect(result == history + " quelque chose de complètement nouveau")
    }

    @Test
    func repeatedSlidingWindowNeverCreatesASecondCopy() {
        var assembler = StreamingTranscriptAssembler()
        let phrase = "Le texte doit défiler doucement sans disparaître ni revenir plusieurs fois"

        _ = assembler.ingest(phrase)
        _ = assembler.ingest(phrase)
        let result = assembler.ingest("\(phrase) lorsque la dictée devient plus longue")

        #expect(result == "\(phrase) lorsque la dictée devient plus longue")
    }
}
