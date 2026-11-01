import AppKit
import Testing
@testable import MoDict

struct TextCaretLocatorTests {
    @Test
    func onlyACaretAfterSomeTextHasAnInsertionPoint() {
        #expect(TextCaretLocator.insertionPoint(of: CFRange(location: 3, length: 0)) == 3)
        #expect(TextCaretLocator.insertionPoint(of: CFRange(location: 0, length: 0)) == nil)
        #expect(TextCaretLocator.insertionPoint(of: CFRange(location: 3, length: 2)) == nil)
    }

    @Test
    func readsWholeComposedCharacters() {
        #expect(TextCaretLocator.character(before: 3, in: "abc") == "c")
        #expect(TextCaretLocator.character(before: 1, in: "abc") == "a")
        #expect(TextCaretLocator.character(before: 2, in: "e\u{301}") == "é")
        #expect(TextCaretLocator.character(before: 2, in: "👍") == "👍")
        #expect(TextCaretLocator.character(before: 4, in: "🇫🇷") == "🇫🇷")
    }

    @Test
    func outOfRangeOrBrokenTextIsNil() {
        #expect(TextCaretLocator.character(before: 0, in: "abc") == nil)
        #expect(TextCaretLocator.character(before: 4, in: "abc") == nil)
        #expect(TextCaretLocator.character(before: 1, in: "") == nil)
        #expect(TextCaretLocator.character(before: 1, in: Self.loneSurrogate) == nil)
    }

    @Test
    func aSingleUnitIsWholeUnlessItIsTheTailOfACharacter() {
        #expect(TextCaretLocator.isWholeCharacter("a"))
        #expect(TextCaretLocator.isWholeCharacter("é"))
        #expect(TextCaretLocator.isWholeCharacter("ab"))
        #expect(!TextCaretLocator.isWholeCharacter(""))
        #expect(!TextCaretLocator.isWholeCharacter("\u{301}"))
        #expect(!TextCaretLocator.isWholeCharacter("\u{FE0F}"))
        #expect(!TextCaretLocator.isWholeCharacter("\u{200D}"))
        #expect(!TextCaretLocator.isWholeCharacter(Self.loneSurrogate))
    }

    private static var loneSurrogate: NSString {
        var unit: unichar = 0xDC4D
        return NSString(characters: &unit, length: 1)
    }
}
