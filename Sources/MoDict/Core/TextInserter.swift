import AppKit
import ApplicationServices
import Carbon            // IsSecureEventInputEnabled
import CoreGraphics

/// Result of an insertion attempt, consumed by `DictationController`.
enum InsertOutcome: Equatable, Sendable {
    enum FailureReason: Equatable, Sendable {
        case pasteboardWriteFailed
        case pasteShortcutFailed
        case cancelled
    }

    case inserted
    case secureInputBlocked
    case noAccessibilityPermission
    case failed(FailureReason)
}

/// Inserts transcribed text at the cursor of whatever app is focused.
///
/// Strategy (matching VoiceInk, the only method that works across native Cocoa,
/// browsers, Electron and terminals): put the text on the pasteboard, synthesise
/// ⌘V, then let `PasteClipboard` restore the previous contents on its own
/// schedule when `settings.restoreClipboard` is on.
///
/// No AX-write path: `kAXSelectedTextAttribute` is unreliable on Chromium/Electron
/// and terminals and caps out around 2040 characters, so it is deliberately absent.
@MainActor
final class TextInserter {

    /// What insertion needs from the system, replaceable so tests never post events.
    struct Host {
        /// Why nothing can be delivered right now, if anything.
        var blockedOutcome: @MainActor () -> InsertOutcome?
        var characterBeforeCaret: @MainActor () -> Character?
        var characterAfterCaret: @MainActor () -> Character?
        /// Prepares ⌘V without posting it. The returned closure posts it; nil means
        /// the events could not be created.
        var preparePaste: @MainActor () -> (@MainActor () async -> Void)?

        static let system = Host(
            blockedOutcome: {
                // Secure input (password fields, Terminal's Secure Keyboard Entry) blocks
                // event taps, synthetic events and AX alike — bail before a silent failure.
                if IsSecureEventInputEnabled() { return .secureInputBlocked }
                // Posting ⌘V requires the Accessibility grant; without it nothing is delivered.
                return AXIsProcessTrusted() ? nil : .noAccessibilityPermission
            },
            characterBeforeCaret: { TextCaretLocator.characterBeforeCaret() },
            characterAfterCaret: { TextCaretLocator.characterAfterCaret() },
            preparePaste: {
                guard let events = TextInserter.pasteEvents(virtualKey: PasteKeyResolver.current()) else { return nil }
                return { await TextInserter.post(events) }
            }
        )
    }

    // Timings validated against VoiceInk's paste pipeline.
    private static let prePasteDelay: UInt64    = 100_000_000   // 0.10 s
    private static let interEventDelay: UInt64  = 10_000_000    // 0.01 s

    private static let keyCommand: CGKeyCode = 0x37

    private let settings: SettingsStore
    private let clipboard: PasteClipboard
    private let host: Host

    convenience init(settings: SettingsStore) {
        self.init(settings: settings, clipboard: PasteClipboard(pasteboard: .general), host: .system)
    }

    init(settings: SettingsStore, clipboard: PasteClipboard, host: Host) {
        self.settings = settings
        self.clipboard = clipboard
        self.host = host
    }

    func insert(_ text: String) async -> InsertOutcome {
        guard !text.isEmpty else { return .inserted }
        guard !Task.isCancelled else { return .failed(.cancelled) }

        if let blocked = host.blockedOutcome() { return blocked }

        let spaced = spacedForCaret(text)
        guard !Task.isCancelled else { return .failed(.cancelled) }
        guard let ticket = clipboard.write(spaced, restoring: settings.restoreClipboard) else {
            return .failed(.pasteboardWriteFailed)
        }

        try? await Task.sleep(nanoseconds: Self.prePasteDelay)
        guard !Task.isCancelled else {
            clipboard.restoreNow(ticket)
            return .failed(.cancelled)
        }
        guard let postPaste = host.preparePaste() else {
            clipboard.restoreNow(ticket)
            return .failed(.pasteShortcutFailed)
        }

        // Commit point: from here the text lands, so the caller can no longer
        // cancel it. An unstructured task keeps cancellation from collapsing the
        // delays between events, or from losing the restore.
        let clipboard = clipboard
        await Task { @MainActor in
            await postPaste()
            clipboard.schedulePasteRestore(ticket)
        }.value
        return .inserted
    }

    /// For app termination; see `PasteClipboard.flushPendingRestore`.
    func flushPendingRestore() {
        clipboard.flushPendingRestore()
    }

    private func spacedForCaret(_ text: String) -> String {
        guard settings.smartSpacing,
              let previous = host.characterBeforeCaret(),
              SmartSpacing.needsLeadingSpace(previous: previous, next: host.characterAfterCaret(), text: text)
        else { return text }
        return " " + text
    }

    // MARK: - Synthetic ⌘V

    /// ⌘V for the HID tap: Command down, V down, V up, Command up. Command is
    /// released with cleared flags so the modifier does not leak into subsequent events.
    static func pasteEvents(virtualKey: CGKeyCode) -> [CGEvent]? {
        let source = CGEventSource(stateID: .privateState)
        source?.userData = SyntheticEvents.marker
        guard let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: keyCommand, keyDown: true),
              let vDown   = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true),
              let vUp     = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false),
              let cmdUp   = CGEvent(keyboardEventSource: source, virtualKey: keyCommand, keyDown: false)
        else { return nil }

        cmdDown.flags = .maskCommand
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand
        return [cmdDown, vDown, vUp, cmdUp]
    }

    private static func post(_ events: [CGEvent]) async {
        for (index, event) in events.enumerated() {
            if index > 0 { try? await Task.sleep(nanoseconds: interEventDelay) }
            event.post(tap: .cghidEventTap)
        }
    }
}
