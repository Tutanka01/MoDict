import AppKit
import ApplicationServices

/// Finds the focused text insertion point through the Accessibility API, so the
/// composition card can sit where the words will actually land. That is the
/// text cursor, which is often far from the mouse pointer.
///
/// Read-only and best-effort: it reuses the Accessibility permission MoDict
/// already holds for pasting, never writes an attribute, and never enables an
/// app's enhanced accessibility mode. Apps that don't report a caret
/// (terminals, many Electron apps) return nil and the card falls back to the
/// pointer.
enum TextCaretLocator {
    /// Upper bound for each synchronous AX round trip. The lookup runs on
    /// key-down, before the card appears; a responsive app answers in a few
    /// milliseconds, and a hung one must never delay the card noticeably.
    private static let messagingTimeout: Float = 0.04

    /// The caret rectangle in AppKit screen coordinates (bottom-left origin),
    /// or nil when the focused element exposes no plausible insertion point.
    @MainActor
    static func caretRect() -> NSRect? {
        // Our own windows (the setup trial editor): a synchronous AX request
        // to this process would wait on the main thread it is running on, so
        // ask the text view directly.
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            return ownCaretRect()
        }
        guard AXIsProcessTrusted(), let axRect = axCaretRect() else { return nil }
        return appKitRect(fromAX: axRect)
    }

    @MainActor
    private static func ownCaretRect() -> NSRect? {
        guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView else { return nil }
        let range = NSRange(location: textView.selectedRange().location, length: 0)
        let rect = textView.firstRect(forCharacterRange: range, actualRange: nil)
        return isPlausibleCaret(rect) ? rect : nil
    }

    /// Accessibility reports top-left-origin rects relative to the primary
    /// display; AppKit's screen space is bottom-left-origin.
    static func appKitRect(fromAX rect: CGRect, primaryScreenHeight: CGFloat? = nil) -> NSRect? {
        guard let height = primaryScreenHeight ?? NSScreen.screens.first?.frame.height else { return nil }
        return NSRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Rejects the placeholder rects some apps return instead of an error:
    /// empty, at the origin, huge (a whole text area), or not finite.
    static func isPlausibleCaret(_ rect: CGRect) -> Bool {
        guard rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite else { return false }
        guard rect.height >= 4, rect.height <= 200, rect.width >= 0, rect.width <= 200 else { return false }
        return !(rect.origin.x == 0 && rect.origin.y == 0)
    }

    // MARK: Character before the caret

    /// The character just before an empty selection, or nil whenever that can't
    /// be established: a real selection, the start of the text, no answer.
    @MainActor
    static func characterBeforeCaret() -> Character? {
        // Same reason as `caretRect`: AX to ourselves would deadlock.
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView else { return nil }
            let selection = textView.selectedRange()
            guard let location = insertionPoint(of: CFRange(location: selection.location, length: selection.length)) else {
                return nil
            }
            return character(before: location, in: textView.string as NSString)
        }
        guard AXIsProcessTrusted() else { return nil }
        return axCharacterBeforeCaret()
    }

    /// The character right after the caret, or nil when there is none or it cannot be read.
    @MainActor
    static func characterAfterCaret() -> Character? {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView else { return nil }
            let text = textView.string as NSString
            let location = textView.selectedRange().location
            guard location < text.length else { return nil }
            return text.substring(with: text.rangeOfComposedCharacterSequence(at: location)).first
        }
        guard AXIsProcessTrusted() else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, messagingTimeout)
        guard let focused = element(systemWide, kAXFocusedUIElementAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(focused, messagingTimeout)
        guard let range = selectedRange(of: focused), range.length == 0, range.location >= 0,
              let unit = string(of: focused, range: CFRange(location: range.location, length: 1)) else { return nil }
        return (unit as String).first
    }

    /// The caret position, when the selection is a caret with text before it.
    static func insertionPoint(of selection: CFRange) -> Int? {
        selection.length == 0 && selection.location > 0 ? selection.location : nil
    }

    /// The whole user-perceived character ending at `location`, which is in
    /// UTF-16 units as both NSText and AX count them.
    static func character(before location: Int, in text: NSString) -> Character? {
        guard location > 0, location <= text.length else { return nil }
        let range = text.rangeOfComposedCharacterSequence(at: location - 1)
        guard let character = text.substring(with: range).last, character != "\u{FFFD}" else { return nil }
        return character
    }

    /// False when one UTF-16 unit read before the caret is only the tail of a
    /// character: half a surrogate pair, a combining accent, a variation selector.
    static func isWholeCharacter(_ text: NSString) -> Bool {
        guard text.length == 1 else { return text.length > 1 }
        guard let scalar = Unicode.Scalar(text.character(at: 0)) else { return false }
        return !scalar.properties.isGraphemeExtend && scalar != "\u{200D}"
    }

    private static func axCharacterBeforeCaret() -> Character? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, messagingTimeout)
        guard let focused = element(systemWide, kAXFocusedUIElementAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(focused, messagingTimeout)
        guard let range = selectedRange(of: focused),
              let location = insertionPoint(of: range),
              let unit = string(of: focused, range: CFRange(location: location - 1, length: 1)) else { return nil }
        if isWholeCharacter(unit) { return character(before: unit.length, in: unit) }

        // Long enough for a flag or a decomposed letter; a longer emoji sequence
        // is cut short but still ends in a symbol, which is all the caller asks.
        let start = max(0, location - 8)
        guard let window = string(of: focused, range: CFRange(location: start, length: location - start)) else {
            return nil
        }
        return character(before: window.length, in: window)
    }

    // MARK: AX

    private static func axCaretRect() -> CGRect? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, messagingTimeout)
        guard let focused = element(systemWide, kAXFocusedUIElementAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(focused, messagingTimeout)
        guard let range = selectedRange(of: focused), range.location >= 0 else { return nil }

        // The insertion point itself: a zero-length range at the selection
        // start. Cocoa text views answer with a zero-width caret rect.
        if let rect = bounds(of: focused, range: CFRange(location: range.location, length: 0)),
           isPlausibleCaret(rect) {
            return rect
        }
        // Many web and custom text engines only measure real characters:
        // the trailing edge of the previous one, or the leading edge of the next.
        if range.location > 0,
           let rect = bounds(of: focused, range: CFRange(location: range.location - 1, length: 1)),
           isPlausibleCaret(rect) {
            return CGRect(x: rect.maxX, y: rect.minY, width: 0, height: rect.height)
        }
        if let rect = bounds(of: focused, range: CFRange(location: range.location, length: 1)),
           isPlausibleCaret(rect) {
            return CGRect(x: rect.minX, y: rect.minY, width: 0, height: rect.height)
        }
        return nil
    }

    private static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func selectedRange(of element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        var range = CFRange()
        guard AXValueGetType(axValue) == .cfRange, AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
    }

    /// An NSString so a lone surrogate reaches `isWholeCharacter` intact; a Swift
    /// String would already have replaced it.
    private static func string(of element: AXUIElement, range: CFRange) -> NSString? {
        var range = range
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &value
        ) == .success, let value, CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return (value as! CFString) as NSString
    }

    private static func bounds(of element: AXUIElement, range: CFRange) -> CGRect? {
        var range = range
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, parameter, &value
        ) == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        var rect = CGRect.zero
        guard AXValueGetType(axValue) == .cgRect, AXValueGetValue(axValue, .cgRect, &rect) else { return nil }
        return rect
    }
}
