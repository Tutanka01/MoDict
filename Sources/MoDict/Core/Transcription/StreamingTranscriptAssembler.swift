import Foundation

/// Turns sliding-window hypotheses into one stable, cumulative preview
/// document.
///
/// With 1 s chunks, most updates are short fragments of freshly decoded words
/// (the manager dedups against previous tokens), but boundaries are imperfect:
/// a fragment may re-include a few tail words, or a re-decoded window may
/// revise the recent wording. Merging is therefore layered by trust:
/// 1. A shared anchor of ≥3 words near both boundaries → revise the tail.
/// 2. Otherwise a boundary overlap (existing suffix == incoming prefix) →
///    append only the genuinely new words.
/// 3. Otherwise plain append.
/// The document can only shrink through a real anchor revision (bounded to the
/// last few words) — a preview that eats itself backwards reads as data loss.
struct StreamingTranscriptAssembler {
    private struct Anchor {
        let existingStart: Int
        let incomingStart: Int
        let length: Int
        let score: Int
    }

    private var words: [String] = []
    private var normalizedWords: [String] = []

    /// Sliding windows contain roughly a few dozen words; restricting the search
    /// to the recent document tail keeps a long dictation cheap and predictable.
    private static let searchTailWords = 160
    /// Revisions are expected only close to the boundary between updates.
    private static let maximumBoundaryGap = 12
    /// An anchor needs three consecutive matching words: one or two shared
    /// words ("et", "de la") occur constantly in the tail, and splicing on such
    /// a false anchor cuts sentences in half.
    private static let minimumAnchorWords = 3

    var text: String { words.joined(separator: " ") }

    mutating func ingest(_ hypothesis: String) -> String {
        let cleanedHypothesis = TranscriptSanitizer.clean(hypothesis)
        let incoming = split(cleanedHypothesis)
        guard !incoming.isEmpty else { return text }
        let normalizedIncoming = incoming.map(Self.normalized)

        guard !words.isEmpty else {
            adopt(incoming, normalized: normalizedIncoming)
            return text
        }

        if let anchor = bestAnchor(incoming: normalizedIncoming) {
            // Keep everything older than the overlap, then take the newest
            // wording from the incoming hypothesis. This permits small ASR
            // corrections without ever rewriting the stable document prefix.
            words = Array(words[..<anchor.existingStart])
                + Array(incoming[anchor.incomingStart...])
        } else {
            // No trustworthy anchor: append, deduplicating only a boundary
            // overlap (existing suffix == incoming prefix). Never rewrite
            // history here — with ~1 s chunks most updates are short fresh
            // fragments, and a destructive fallback eats the document
            // backwards a dozen words at a time.
            let overlap = boundaryOverlap(incoming: normalizedIncoming)
            words.append(contentsOf: incoming[overlap...])
        }

        // A final local guard handles repeated spans even if a noisy hypothesis
        // briefly defeated boundary matching.
        let sanitized = TranscriptSanitizer.clean(words.joined(separator: " "))
        let sanitizedWords = split(sanitized)
        adopt(sanitizedWords, normalized: sanitizedWords.map(Self.normalized))
        return text
    }

    private mutating func adopt(_ newWords: [String], normalized: [String]) {
        words = newWords
        normalizedWords = normalized
    }

    /// Longest run where the end of the document equals the start of the
    /// incoming fragment. Positionally constrained on both sides, so unlike a
    /// mid-tail anchor even a one-word match is safe to deduplicate.
    private func boundaryOverlap(incoming: [String]) -> Int {
        let bound = min(Self.maximumBoundaryGap, normalizedWords.count, incoming.count)
        var length = bound
        while length > 0 {
            if normalizedWords.suffix(length).elementsEqual(incoming.prefix(length)) {
                return length
            }
            length -= 1
        }
        return 0
    }

    private func bestAnchor(incoming: [String]) -> Anchor? {
        let searchStart = max(0, normalizedWords.count - Self.searchTailWords)
        let minimumLength = Self.minimumAnchorWords
        var best: Anchor?

        for existingStart in searchStart..<normalizedWords.count {
            for incomingStart in 0..<min(incoming.count, Self.maximumBoundaryGap + 1) {
                var length = 0
                while existingStart + length < normalizedWords.count,
                      incomingStart + length < incoming.count,
                      normalizedWords[existingStart + length] == incoming[incomingStart + length] {
                    length += 1
                }
                guard length >= minimumLength else { continue }

                let existingTail = normalizedWords.count - (existingStart + length)
                guard existingTail <= Self.maximumBoundaryGap else { continue }

                // Prefer long anchors, then anchors closest to the old suffix
                // and new prefix. This rejects coincidental phrases in the middle.
                let score = length * 100 - existingTail * 3 - incomingStart * 2
                if best == nil || score > best!.score {
                    best = Anchor(
                        existingStart: existingStart,
                        incomingStart: incomingStart,
                        length: length,
                        score: score
                    )
                }
            }
        }

        return best
    }

    private func split(_ text: String) -> [String] {
        text.split(whereSeparator: \Character.isWhitespace).map(String.init)
    }

    private static func normalized(_ word: String) -> String {
        word.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "fr_FR")
        )
        .trimmingCharacters(in: .punctuationCharacters.union(.symbols))
    }
}
