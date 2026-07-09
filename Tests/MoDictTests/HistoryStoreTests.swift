import AppKit
import Testing
@testable import MoDict

@Suite(.serialized)
@MainActor
struct HistoryStoreTests {

    @Test
    func addTrimsTextRejectsEmptyEntriesAndKeepsNewestFiveFirst() {
        let store = HistoryStore()

        store.add("  first  ")
        store.add("\n\t")
        store.add("second")
        store.add("third")
        store.add("fourth")
        store.add("fifth")
        store.add("sixth")

        #expect(store.items.map(\.text) == ["sixth", "fifth", "fourth", "third", "second"])
    }

    @Test
    func clearRemovesAllItems() {
        let store = HistoryStore()
        store.add("one")
        store.add("two")

        store.clear()

        #expect(store.items.isEmpty)
    }

    @Test
    func copyToClipboardWritesTheItemText() throws {
        let store = HistoryStore()
        let pasteboard = NSPasteboard.general
        let previousString = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let previousString {
                pasteboard.setString(previousString, forType: .string)
            }
        }

        store.add(" copied text ")
        let item = try #require(store.items.first)

        store.copyToClipboard(item)

        #expect(pasteboard.string(forType: .string) == "copied text")
    }
}
