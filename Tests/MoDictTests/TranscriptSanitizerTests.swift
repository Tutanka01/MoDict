import Testing
@testable import MoDict

struct TranscriptSanitizerTests {
    @Test
    func collapsesTheRepeatedBlockSeenInStreamingOutput() {
        let phrase = "Et par contre ça m'a fait un gros bloc de texte vraiment énorme."
        let input = "\(phrase) \(phrase) \(phrase)"

        #expect(TranscriptSanitizer.clean(input) == phrase)
    }

    @Test
    func comparisonIgnoresCaseAccentsAndTrailingPunctuation() {
        let input = "Voilà le très gros bloc qui recommence. voila le tres gros bloc qui recommence !"

        #expect(TranscriptSanitizer.clean(input) == "Voilà le très gros bloc qui recommence.")
    }

    @Test
    func preservesShortIntentionalEmphasis() {
        let input = "Non non, vraiment vraiment, je veux garder ça."

        #expect(TranscriptSanitizer.clean(input) == input)
    }

    @Test
    func normalizesWhitespaceWithoutChangingTheWords() {
        let input = "  Une   phrase\navec\tplusieurs espaces.  "

        #expect(TranscriptSanitizer.clean(input) == "Une phrase avec plusieurs espaces.")
    }
}
