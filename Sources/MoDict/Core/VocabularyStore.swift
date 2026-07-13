import Foundation

/// One user-defined text replacement: what the engine heard → what to insert.
struct VocabularyRule: Identifiable, Codable, Equatable {
    let id: UUID
    var phrase: String        // what the engine heard
    var replacement: String   // what to insert instead

    init(id: UUID = UUID(), phrase: String, replacement: String) {
        self.id = id
        self.phrase = phrase
        self.replacement = replacement
    }
}

/// Personal vocabulary applied to every transcription before insertion, so proper
/// nouns and technical terms the model mishears ("mo dict" → "MoDict") come out
/// right. Persisted as JSON to UserDefaults. All access on the main actor.
@MainActor
final class VocabularyStore: ObservableObject {

    @Published var rules: [VocabularyRule] {
        didSet { persist() }
    }

    private let defaults: UserDefaults
    private static let storageKey = "vocabularyRules"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([VocabularyRule].self, from: data) {
            rules = decoded
        } else {
            rules = []
        }
    }

    /// Rewrite `text` with every rule, in a single non-overlapping left-to-right pass.
    /// Longer phrases win at a shared position (longest-match priority). See the unit
    /// tests for the exact matching, casing, and deletion semantics.
    func apply(to text: String) -> String {
        // Longest phrases first so alternation prefers them (ICU alternation is
        // ordered, not longest-match), giving longest-match priority.
        let active = rules
            .filter { !$0.phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.phrase.trimmingCharacters(in: .whitespacesAndNewlines).count
                    > $1.phrase.trimmingCharacters(in: .whitespacesAndNewlines).count }
        guard !active.isEmpty else { return text }

        // Each rule becomes one capture group inside a shared alternation. `\b`
        // misbehaves around non-ASCII, so boundaries are letter/number lookarounds.
        var groupPatterns: [String] = []
        var groupRules: [VocabularyRule] = []
        for rule in active {
            let phrase = rule.phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            let tokens = phrase.split(whereSeparator: { $0.isWhitespace })
                .map { NSRegularExpression.escapedPattern(for: String($0)) }
            // Internal whitespace matches any single run of whitespace in the text.
            groupPatterns.append("(" + tokens.joined(separator: "\\s+") + ")")
            groupRules.append(rule)
        }

        let pattern = "(?<![\\p{L}\\p{N}])(?:" + groupPatterns.joined(separator: "|") + ")(?![\\p{L}\\p{N}])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }

        let ns = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }

        var result = ""
        var lastEnd = 0
        var deletionOccurred = false
        for match in matches {
            let full = match.range
            result += ns.substring(with: NSRange(location: lastEnd, length: full.location - lastEnd))

            var matchedRule: VocabularyRule?
            for group in 1...groupRules.count where match.range(at: group).location != NSNotFound {
                matchedRule = groupRules[group - 1]
                break
            }

            let occurrence = ns.substring(with: full)
            if let rule = matchedRule {
                let replacement = adaptedReplacement(for: rule, occurrence: occurrence)
                if replacement.isEmpty { deletionOccurred = true }
                result += replacement
            } else {
                result += occurrence
            }
            lastEnd = full.location + full.length
        }
        result += ns.substring(from: lastEnd)

        if deletionOccurred {
            // A deletion can leave doubled spaces or an edge space behind.
            result = result.replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    /// Any uppercase in the replacement means the user chose exact casing (use it
    /// verbatim). An all-lowercase replacement adapts its first letter to the
    /// matched occurrence, so a sentence-start match stays capitalized.
    private func adaptedReplacement(for rule: VocabularyRule, occurrence: String) -> String {
        let replacement = rule.replacement
        guard !replacement.isEmpty else { return "" }
        if replacement.contains(where: { $0.isUppercase }) { return replacement }
        if let first = occurrence.first, first.isUppercase {
            return replacement.prefix(1).uppercased() + replacement.dropFirst()
        }
        return replacement
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(rules) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}
