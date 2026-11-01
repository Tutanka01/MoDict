/// Decides whether dictated text needs a space to avoid gluing onto what is
/// already before the caret ("Bonjour.Comment ça va").
enum SmartSpacing {
    /// Sentence and bracket closers: a new phrase starts after them, with a space.
    private static let spacedAfter: Set<Character> = [".", ",", ";", ":", "!", "?", "…", ")", "]", "}", "»", "”"]
    /// Text starting with these attaches to the previous word.
    private static let attachedBefore: Set<Character> = [",", ".", ";", ":", "!", "?", "…", ")", "]", "}", "»", "”", "'", "’", "-", "/", "%"]
    /// Between digits these join a number, a time or a version: "3,5", "12:30", "1.2".
    private static let digitJoiners: Set<Character> = [".", ",", ":"]

    /// An allow-list on purpose: anything not known to end a word (opening
    /// punctuation, the apostrophe of French elision, hyphens, symbols) stays
    /// attached, because a missing space is cheaper than one inside "l’ami".
    ///
    /// `next` is the character after the caret, when known: text going into the
    /// middle of a word was placed there on purpose.
    static func needsLeadingSpace(previous: Character, next: Character? = nil, text: String) -> Bool {
        guard let first = text.first, !first.isWhitespace, !attachedBefore.contains(first) else { return false }
        if let next, next.isLetter || next.isNumber { return false }
        if first.isNumber, digitJoiners.contains(previous) { return false }
        guard !writtenWithoutSpaces(previous) else { return false }
        return previous.isLetter || previous.isNumber || spacedAfter.contains(previous)
    }

    /// Chinese, Japanese, Thai, Lao, Khmer and Burmese do not put spaces between
    /// sentences or words.
    private static func writtenWithoutSpaces(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first?.value else { return false }
        switch scalar {
        case 0x0E00...0x0EFF,      // Thai, Lao
             0x1000...0x109F,      // Burmese
             0x1780...0x17FF,      // Khmer
             0x3040...0x30FF,      // Hiragana, Katakana
             0x3400...0x4DBF,      // CJK extension A
             0x4E00...0x9FFF,      // CJK unified
             0xF900...0xFAFF,      // CJK compatibility
             0x20000...0x323AF:    // CJK supplementary
            return true
        default:
            return false
        }
    }
}
