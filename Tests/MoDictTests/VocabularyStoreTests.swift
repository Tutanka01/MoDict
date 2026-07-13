import Foundation
import Testing
@testable import MoDict

@MainActor
struct VocabularyStoreTests {

    // MARK: apply(to:)

    @Test
    func matchesOnlyWholeWordsAndNotInsideOtherWords() {
        let store = makeStore(rules: [VocabularyRule(phrase: "cat", replacement: "dog")])

        #expect(store.apply(to: "the cat sat") == "the dog sat")
        #expect(store.apply(to: "concatenate the scatter") == "concatenate the scatter")
    }

    @Test
    func matchingIsCaseInsensitive() {
        let store = makeStore(rules: [VocabularyRule(phrase: "kubectl", replacement: "kubectl")])

        #expect(store.apply(to: "run KUBECTL now") == "run kubectl now")
    }

    @Test
    func lowercaseReplacementAdaptsToUppercaseOccurrence() {
        let store = makeStore(rules: [VocabularyRule(phrase: "cube control", replacement: "kubectl")])

        // Sentence start: occurrence "Cube control" is capitalized → replacement follows.
        #expect(store.apply(to: "Cube control is handy") == "Kubectl is handy")
        // Lowercase occurrence keeps the replacement lowercase.
        #expect(store.apply(to: "use cube control") == "use kubectl")
    }

    @Test
    func mixedCaseReplacementIsUsedVerbatim() {
        let store = makeStore(rules: [VocabularyRule(phrase: "mo dict", replacement: "MoDict")])

        #expect(store.apply(to: "I love mo dict") == "I love MoDict")
        #expect(store.apply(to: "Mo dict rocks") == "MoDict rocks")
    }

    @Test
    func multiWordPhraseMatchesFlexibleWhitespace() {
        let store = makeStore(rules: [VocabularyRule(phrase: "mo dict", replacement: "MoDict")])

        #expect(store.apply(to: "open mo   dict here") == "open MoDict here")
        #expect(store.apply(to: "open mo\tdict here") == "open MoDict here")
    }

    @Test
    func longerPhrasesWinOverShorterOnes() {
        let store = makeStore(rules: [
            VocabularyRule(phrase: "york", replacement: "York"),
            VocabularyRule(phrase: "new york", replacement: "New York City"),
        ])

        #expect(store.apply(to: "in new york today") == "in New York City today")
    }

    @Test
    func replacedTextIsNotReMatchedBySubsequentRules() {
        // "ab" → "cat"; "cat" → "dog". A single non-overlapping pass must not turn
        // the freshly written "cat" into "dog".
        let store = makeStore(rules: [
            VocabularyRule(phrase: "ab", replacement: "cat"),
            VocabularyRule(phrase: "cat", replacement: "dog"),
        ])

        #expect(store.apply(to: "the ab and the cat") == "the cat and the dog")
    }

    @Test
    func emptyReplacementDeletesPhraseAndCollapsesSpaces() {
        let store = makeStore(rules: [VocabularyRule(phrase: "um", replacement: "")])

        #expect(store.apply(to: "well um okay") == "well okay")
        #expect(store.apply(to: "um leading") == "leading")
        #expect(store.apply(to: "trailing um") == "trailing")
    }

    @Test
    func emptyOrWhitespacePhrasesAreIgnored() {
        let store = makeStore(rules: [
            VocabularyRule(phrase: "   ", replacement: "x"),
            VocabularyRule(phrase: "", replacement: "y"),
        ])

        #expect(store.apply(to: "nothing changes here") == "nothing changes here")
    }

    @Test
    func textWithNoRulesIsUnchanged() {
        let store = makeStore(rules: [])

        #expect(store.apply(to: "unchanged text") == "unchanged text")
    }

    // MARK: Persistence

    @Test
    func rulesRoundTripThroughUserDefaults() {
        withEmptyDefaults { defaults in
            let store = VocabularyStore(defaults: defaults)
            let rule = VocabularyRule(phrase: "mo dict", replacement: "MoDict")
            store.rules = [rule]

            let reloaded = VocabularyStore(defaults: defaults)
            #expect(reloaded.rules == [rule])
        }
    }

    @Test
    func defaultsToNoRulesWhenDomainIsEmpty() {
        withEmptyDefaults { defaults in
            let store = VocabularyStore(defaults: defaults)
            #expect(store.rules.isEmpty)
        }
    }

    // MARK: Helpers

    private func makeStore(rules: [VocabularyRule]) -> VocabularyStore {
        let suiteName = "MoDictTests.Vocabulary.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = VocabularyStore(defaults: defaults)
        store.rules = rules
        return store
    }

    private func withEmptyDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "MoDictTests.Vocabulary.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(defaults)
    }
}
