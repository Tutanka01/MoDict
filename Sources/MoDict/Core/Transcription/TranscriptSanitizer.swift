import Foundation

/// Last line of defence between ASR output and the user's focused application.
///
/// The canonical transcription is produced from the full utterance, but model or
/// windowing regressions must still never paste the same long phrase repeatedly.
/// Only adjacent repetitions of at least five words are collapsed, preserving
/// natural emphasis such as "très très" or "oui oui".
enum TranscriptSanitizer {
    private static let minimumRepeatedPhraseWords = 5
    /// Bounds work for exceptionally long dictations. Longer duplicated spans
    /// are still removed over multiple adjacent chunks.
    private static let maximumRepeatedPhraseWords = 128

    static func clean(_ text: String) -> String {
        var words = text.split(whereSeparator: \Character.isWhitespace).map(String.init)
        guard !words.isEmpty else { return "" }
        var normalizedWords = words.map(normalized)

        var start = 0
        while start + minimumRepeatedPhraseWords * 2 <= words.count {
            let remaining = words.count - start
            let largestCandidate = min(remaining / 2, maximumRepeatedPhraseWords)
            var removedRepeat = false

            if largestCandidate >= minimumRepeatedPhraseWords {
                for length in stride(
                    from: largestCandidate,
                    through: minimumRepeatedPhraseWords,
                    by: -1
                ) {
                    let normalizedFirst = normalizedWords[start..<(start + length)]
                    let normalizedSecond = normalizedWords[(start + length)..<(start + length * 2)]
                    guard normalizedFirst.elementsEqual(normalizedSecond) else { continue }

                    words.removeSubrange((start + length)..<(start + length * 2))
                    normalizedWords.removeSubrange((start + length)..<(start + length * 2))
                    start = max(0, start - length)
                    removedRepeat = true
                    break
                }
            }

            if !removedRepeat { start += 1 }
        }

        return words.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalized(_ word: String) -> String {
        word.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "fr_FR")
        )
        .trimmingCharacters(in: .punctuationCharacters.union(.symbols))
    }
}
