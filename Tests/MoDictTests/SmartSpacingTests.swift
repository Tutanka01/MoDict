import Testing
@testable import MoDict

struct SmartSpacingTests {
    @Test(arguments: Array("aZéя7.,;:!?…)]}»”") as [Character])
    func spaceFollowsWordsAndClosingPunctuation(previous: Character) {
        #expect(SmartSpacing.needsLeadingSpace(previous: previous, text: "Comment"))
    }

    @Test(arguments: [" ", "\n", "\t", "\u{00A0}", "(", "[", "{", "«", "“", "'", "’", "-", "/", "@", "$", "#", "€", "+", "👍"] as [Character])
    func noSpaceAfterOpeningsApostrophesAndSymbols(previous: Character) {
        #expect(!SmartSpacing.needsLeadingSpace(previous: previous, text: "ami"))
    }

    @Test(arguments: [",", ".", ";", ":", "!", "?", "…", ")", "]", "}", "»", "”", "'", "’", "-", "/", "%"])
    func noSpaceBeforeClosingPunctuation(first: String) {
        #expect(!SmartSpacing.needsLeadingSpace(previous: "a", text: first + " suite"))
    }

    @Test(arguments: [" !", "\u{00A0}!", "\u{202F}?", "\nSuite", ""])
    func noSpaceBeforeWhitespaceOrNothing(text: String) {
        #expect(!SmartSpacing.needsLeadingSpace(previous: "a", text: text))
    }

    @Test(arguments: ["好", "あ", "カ", "ก", "ສ", "က", "ក"] as [Character])
    func noSpaceInScriptsWrittenWithoutSpaces(previous: Character) {
        #expect(!SmartSpacing.needsLeadingSpace(previous: previous, text: "下一句"))
    }

    @Test(arguments: [",", ".", ":"] as [Character])
    func digitsAfterAJoinerStayAttached(previous: Character) {
        #expect(!SmartSpacing.needsLeadingSpace(previous: previous, text: "5"))
        #expect(SmartSpacing.needsLeadingSpace(previous: previous, text: "Cinq"))
    }

    @Test
    func theMiddleOfAWordGetsNoSpace() {
        #expect(!SmartSpacing.needsLeadingSpace(previous: "l", next: "o", text: "foo"))
        #expect(!SmartSpacing.needsLeadingSpace(previous: "1", next: "2", text: "foo"))
        #expect(SmartSpacing.needsLeadingSpace(previous: "l", next: " ", text: "foo"))
        #expect(SmartSpacing.needsLeadingSpace(previous: "l", next: ".", text: "foo"))
        #expect(SmartSpacing.needsLeadingSpace(previous: "l", next: nil, text: "foo"))
    }

    @Test
    func koreanKeepsItsSpaces() {
        #expect(SmartSpacing.needsLeadingSpace(previous: "요", text: "다음"))
    }

    @Test
    func typicalDictations() {
        #expect(SmartSpacing.needsLeadingSpace(previous: ".", text: "Comment ça va"))
        #expect(SmartSpacing.needsLeadingSpace(previous: "e\u{301}", text: "Suite"))
        #expect(!SmartSpacing.needsLeadingSpace(previous: "’", text: "ami"))
        #expect(SmartSpacing.needsLeadingSpace(previous: "a", text: "(note)"))
    }
}
