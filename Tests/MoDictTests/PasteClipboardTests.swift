import AppKit
import Testing
@testable import MoDict

/// Always on a private pasteboard, with the restore timer fired by hand.
@MainActor
final class PasteClipboardTests {
    private nonisolated(unsafe) let pasteboard = NSPasteboard(name: NSPasteboard.Name("MoDictTests.\(UUID().uuidString)"))
    private var timers: [(delay: Duration, action: @MainActor () -> Void)] = []
    private lazy var clipboard = PasteClipboard(pasteboard: pasteboard, schedule: { [unowned self] delay, action in
        timers.append((delay, action))
    })

    deinit { pasteboard.releaseGlobally() }

    private func copy(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private var contents: String? { pasteboard.string(forType: .string) }

    @Test
    func restoresTheOriginalOnlyWhenTheTimerFires() throws {
        copy("original")
        let ticket = try #require(clipboard.write("dictated", restoring: true))
        #expect(contents == "dictated")

        clipboard.schedulePasteRestore(ticket)
        #expect(contents == "dictated")
        #expect(timers.map(\.delay) == [.milliseconds(500)])

        timers[0].action()
        #expect(contents == "original")
    }

    @Test
    func snapshotKeepsEveryItemAndType() throws {
        let custom = NSPasteboard.PasteboardType("com.modict.test.custom")
        let first = NSPasteboardItem()
        first.setString("one", forType: .string)
        first.setData(Data([1, 2, 3]), forType: custom)
        let second = NSPasteboardItem()
        second.setString("two", forType: .string)
        pasteboard.clearContents()
        pasteboard.writeObjects([first, second])

        let ticket = try #require(clipboard.write("dictated", restoring: true))
        clipboard.restoreNow(ticket)

        let items = try #require(pasteboard.pasteboardItems)
        #expect(items.count == 2)
        #expect(items[0].string(forType: .string) == "one")
        #expect(items[0].data(forType: custom) == Data([1, 2, 3]))
        #expect(items[1].string(forType: .string) == "two")
    }

    @Test
    func emptyOriginalIsRestoredAsEmpty() throws {
        pasteboard.clearContents()
        let ticket = try #require(clipboard.write("dictated", restoring: true))
        clipboard.schedulePasteRestore(ticket)
        timers[0].action()
        #expect(contents == nil)
    }

    @Test
    func aCopyMadeMeanwhileIsNeverClobbered() throws {
        copy("original")
        let ticket = try #require(clipboard.write("dictated", restoring: true))
        clipboard.schedulePasteRestore(ticket)

        copy("copied meanwhile")
        timers[0].action()
        #expect(contents == "copied meanwhile")
    }

    @Test
    func aCopyOfTheSameTextIsStillNotOurs() throws {
        copy("original")
        let ticket = try #require(clipboard.write("dictated", restoring: true))
        clipboard.schedulePasteRestore(ticket)

        copy("dictated")   // same string, no session marker
        timers[0].action()
        #expect(contents == "dictated")
    }

    @Test
    func secondPasteKeepsTheOriginalAndSupersedesTheFirstTimer() throws {
        copy("original")
        let first = try #require(clipboard.write("one", restoring: true))
        clipboard.schedulePasteRestore(first)

        let second = try #require(clipboard.write("two", restoring: true))
        #expect(contents == "two")
        clipboard.schedulePasteRestore(second)
        #expect(timers.count == 2)

        timers[0].action()   // the superseded timer changes nothing
        #expect(contents == "two")

        timers[1].action()
        #expect(contents == "original")
    }

    @Test
    func secondPasteBeforeTheFirstTimerWasArmedAlsoKeepsTheOriginal() throws {
        copy("original")
        let first = try #require(clipboard.write("one", restoring: true))
        let second = try #require(clipboard.write("two", restoring: true))

        clipboard.restoreNow(first)   // the first dictation, cancelled late
        #expect(contents == "two")
        clipboard.schedulePasteRestore(first)
        #expect(timers.isEmpty)

        clipboard.restoreNow(second)
        #expect(contents == "original")
    }

    @Test
    func aCopyBetweenPastesBecomesTheNewOriginal() throws {
        copy("original")
        let first = try #require(clipboard.write("one", restoring: true))
        clipboard.schedulePasteRestore(first)

        copy("copied meanwhile")
        let second = try #require(clipboard.write("two", restoring: true))
        clipboard.schedulePasteRestore(second)

        timers[1].action()
        #expect(contents == "copied meanwhile")
    }

    @Test
    func aFiredRestoreLeavesNothingHeld() throws {
        copy("original")
        let first = try #require(clipboard.write("one", restoring: true))
        clipboard.schedulePasteRestore(first)
        timers[0].action()

        copy("next")
        let second = try #require(clipboard.write("two", restoring: true))
        clipboard.schedulePasteRestore(second)
        timers[1].action()
        #expect(contents == "next")
    }

    @Test
    func restoreOffWritesNoMarkerAndNeverRestores() throws {
        copy("original")
        let ticket = try #require(clipboard.write("dictated", restoring: false))
        #expect(pasteboard.string(forType: NSPasteboard.PasteboardType("com.modict.PasteSession")) == nil)
        #expect(pasteboard.data(forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) == nil)

        clipboard.schedulePasteRestore(ticket)
        clipboard.restoreNow(ticket)
        #expect(timers.isEmpty)
        #expect(contents == "dictated")
    }

    @Test
    func restoreOnMarksThePasteAsTransient() throws {
        copy("original")
        _ = try #require(clipboard.write("dictated", restoring: true))
        #expect(pasteboard.string(forType: NSPasteboard.PasteboardType("com.modict.PasteSession")) != nil)
        #expect(pasteboard.data(forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) != nil)
        #expect(pasteboard.data(forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")) != nil)
    }

    @Test
    func failedWriteRestoresImmediately() {
        copy("original")
        let failing = PasteClipboard(pasteboard: pasteboard, schedule: { _, _ in }, writeString: { _, _ in false })
        #expect(failing.write("dictated", restoring: true) == nil)
        #expect(contents == "original")
    }

    @Test
    func failedWriteDuringAPendingRestoreGivesBackTheFirstOriginal() throws {
        copy("original")
        var fails = false
        let flaky = PasteClipboard(pasteboard: pasteboard, schedule: { _, _ in }, writeString: { pasteboard, text in
            !fails && pasteboard.setString(text, forType: .string)
        })
        let first = try #require(flaky.write("one", restoring: true))
        flaky.schedulePasteRestore(first)

        fails = true
        #expect(flaky.write("two", restoring: true) == nil)
        #expect(contents == "original")
    }

    @Test
    func sleepingSchedulerWaitsDespiteTheCallersCancellation() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        var firedAfter: Duration?
        await Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            PasteClipboard.sleepingScheduler(.milliseconds(30)) { firedAfter = start.duration(to: clock.now) }
        }.value

        while firedAfter == nil, start.duration(to: clock.now) < .seconds(5) {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(try #require(firedAfter) >= .milliseconds(30))
    }

    @Test
    func quittingRestoresAtOnceWithoutTheTimer() throws {
        pasteboard.clearContents()
        pasteboard.setString("before", forType: .string)
        let ticket = try #require(clipboard.write("dictated", restoring: true))
        clipboard.schedulePasteRestore(ticket)
        clipboard.flushPendingRestore()
        #expect(pasteboard.string(forType: .string) == "before")
    }

    @Test
    func quittingLeavesAUserCopyAlone() throws {
        pasteboard.clearContents()
        pasteboard.setString("before", forType: .string)
        let ticket = try #require(clipboard.write("dictated", restoring: true))
        clipboard.schedulePasteRestore(ticket)
        pasteboard.clearContents()
        pasteboard.setString("user copy", forType: .string)
        clipboard.flushPendingRestore()
        #expect(pasteboard.string(forType: .string) == "user copy")
    }
}
