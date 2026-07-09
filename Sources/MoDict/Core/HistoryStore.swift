import AppKit
import Foundation

/// Recent transcriptions, kept only in memory (privacy — nothing touches disk).
/// The menu bar reads `items` and can re-copy any entry to the clipboard.
@MainActor
final class HistoryStore: ObservableObject {

    struct Item: Identifiable, Equatable {
        let id: UUID
        let text: String
        let date: Date

        init(text: String, date: Date = Date()) {
            self.id = UUID()
            self.text = text
            self.date = date
        }
    }

    /// Newest first, capped at `maxItems`.
    @Published private(set) var items: [Item] = []

    private static let maxItems = 5

    func add(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        items.insert(Item(text: trimmed), at: 0)
        if items.count > Self.maxItems {
            items.removeLast(items.count - Self.maxItems)
        }
    }

    func copyToClipboard(_ item: Item) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.text, forType: .string)
    }

    func clear() {
        items.removeAll()
    }
}
