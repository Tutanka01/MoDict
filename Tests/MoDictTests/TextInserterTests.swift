import AppKit
import Testing
@testable import MoDict

/// Drives `insert` through an injected host: no event is ever posted, and the
/// pasteboard is private.
@MainActor
final class TextInserterTests {
    private nonisolated(unsafe) let pasteboard = NSPasteboard(name: NSPasteboard.Name("MoDictTests.\(UUID().uuidString)"))
    private let suiteName = "MoDictTests.TextInserter.\(UUID().uuidString)"
    private lazy var settings = SettingsStore(defaults: UserDefaults(suiteName: suiteName)!)
    private var timers: [@MainActor () -> Void] = []
    private var caret: Character?
    private var caretReads = 0
    private var posts = 0

    deinit {
        pasteboard.releaseGlobally()
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    private func makeInserter(blocked: InsertOutcome? = nil,
                              canPost: Bool = true,
                              onPost: (@MainActor () async -> Void)? = nil,
                              writeSucceeds: Bool = true) -> TextInserter {
        let clipboard = PasteClipboard(pasteboard: pasteboard, schedule: { [unowned self] _, action in
            timers.append(action)
        }, writeString: { pasteboard, text in
            writeSucceeds && pasteboard.setString(text, forType: .string)
        })
        return TextInserter(settings: settings, clipboard: clipboard, host: TextInserter.Host(
            blockedOutcome: { blocked },
            characterBeforeCaret: { [unowned self] in
                caretReads += 1
                return caret
            },
            characterAfterCaret: { nil },
            preparePaste: { [unowned self] in
                guard canPost else { return nil }
                return { [unowned self] in
                    posts += 1
                    await onPost?()
                }
            }
        ))
    }

    private func copy(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private var contents: String? { pasteboard.string(forType: .string) }

    // MARK: Restoration and commit point

    @Test
    func returnsBeforeTheRestoreAndRestoresOnItsOwnSchedule() async {
        copy("original")
        let outcome = await makeInserter().insert("dictated")

        #expect(outcome == .inserted)
        #expect(posts == 1)
        #expect(contents == "dictated")
        #expect(timers.count == 1)

        timers[0]()
        #expect(contents == "original")
    }

    @Test
    func cancellationBeforeTheCommitPointRestoresAndDoesNotPaste() async {
        copy("original")
        let inserter = makeInserter()
        let task = Task { await inserter.insert("dictated") }
        while contents != "dictated" { await Task.yield() }

        task.cancel()   // the insert is now inside the pre-paste delay
        #expect(await task.value == .failed(.cancelled))
        #expect(posts == 0)
        #expect(timers.isEmpty)
        #expect(contents == "original")
    }

    @Test
    func cancellationAfterTheCommitPointStillReportsInserted() async {
        copy("original")
        var task: Task<InsertOutcome, Never>?
        var postingSawCancellation = false
        let inserter = makeInserter(onPost: {
            task?.cancel()
            postingSawCancellation = Task.isCancelled
        })
        task = Task { await inserter.insert("dictated") }

        let outcome = await task!.value
        #expect(task!.isCancelled)
        #expect(outcome == .inserted)
        #expect(!postingSawCancellation)
        #expect(posts == 1)
        #expect(timers.count == 1)

        timers[0]()
        #expect(contents == "original")
    }

    @Test
    func secondInsertWhilePendingKeepsTheOriginal() async {
        copy("original")
        let inserter = makeInserter()
        #expect(await inserter.insert("one") == .inserted)
        #expect(await inserter.insert("two") == .inserted)
        #expect(contents == "two")

        timers[0]()
        #expect(contents == "two")
        timers[1]()
        #expect(contents == "original")
    }

    @Test
    func failedPostingRestoresImmediately() async {
        copy("original")
        let outcome = await makeInserter(canPost: false).insert("dictated")
        #expect(outcome == .failed(.pasteShortcutFailed))
        #expect(timers.isEmpty)
        #expect(contents == "original")
    }

    @Test
    func failedWriteRestoresImmediately() async {
        copy("original")
        let outcome = await makeInserter(writeSucceeds: false).insert("dictated")
        #expect(outcome == .failed(.pasteboardWriteFailed))
        #expect(posts == 0)
        #expect(contents == "original")
    }

    @Test
    func restoreClipboardOffLeavesTheDictatedText() async {
        settings.restoreClipboard = false
        copy("original")
        #expect(await makeInserter().insert("dictated") == .inserted)
        #expect(timers.isEmpty)
        #expect(contents == "dictated")
    }

    // MARK: Gates

    @Test(arguments: [InsertOutcome.secureInputBlocked, .noAccessibilityPermission])
    func blockedInsertTouchesNothing(blocked: InsertOutcome) async {
        copy("original")
        caret = "a"
        #expect(await makeInserter(blocked: blocked).insert("dictated") == blocked)
        #expect(caretReads == 0)
        #expect(posts == 0)
        #expect(contents == "original")
    }

    @Test
    func emptyTextIsANoOp() async {
        copy("original")
        #expect(await makeInserter().insert("") == .inserted)
        #expect(caretReads == 0)
        #expect(posts == 0)
        #expect(contents == "original")
    }

    // MARK: Smart spacing

    @Test
    func addsASpaceAfterTheEndOfASentence() async {
        settings.restoreClipboard = false
        caret = "."
        #expect(await makeInserter().insert("Comment ça va") == .inserted)
        #expect(contents == " Comment ça va")
    }

    @Test
    func keepsTheTextWhenTheCaretCannotBeRead() async {
        settings.restoreClipboard = false
        caret = nil
        #expect(await makeInserter().insert("Comment") == .inserted)
        #expect(contents == "Comment")
    }

    @Test
    func keepsFrenchElisionAttached() async {
        settings.restoreClipboard = false
        caret = "’"
        #expect(await makeInserter().insert("ami") == .inserted)
        #expect(contents == "ami")
    }

    @Test
    func smartSpacingOffNeverReadsTheCaret() async {
        settings.restoreClipboard = false
        settings.smartSpacing = false
        caret = "."
        #expect(await makeInserter().insert("Comment") == .inserted)
        #expect(caretReads == 0)
        #expect(contents == "Comment")
    }

    @Test
    func aSpacedPasteStillRestores() async {
        copy("original")
        caret = "a"
        #expect(await makeInserter().insert("suite") == .inserted)
        #expect(contents == " suite")
        timers[0]()
        #expect(contents == "original")
    }
}
