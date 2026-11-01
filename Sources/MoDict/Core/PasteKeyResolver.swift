import Carbon
import CoreGraphics

/// Finds the key that means "V" while Command is held. Key code 9 is only V's
/// physical QWERTY position: ⌘ + key 9 is ⌘K on Dvorak and ⌘C on Turkish Q.
enum PasteKeyResolver {
    static let fallback: CGKeyCode = 0x09

    /// UCKeyTranslate's modifier state for the Command layer. Layouts such as
    /// "Dvorak – QWERTY ⌘" switch to a different arrangement in this layer, and
    /// non-Latin layouts may have no "v" at all, hence the ASCII-capable fallback.
    private static let commandModifierState = UInt32(cmdKey >> 8) & 0xFF

    /// Read at paste time because the layout can change between dictations.
    /// Text Input Sources must be queried on the main thread.
    @MainActor
    static func current() -> CGKeyCode {
        let layouts = [
            TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()
        ].compactMap { $0 }
        return resolve(layouts: layouts, keyboardType: UInt32(LMGetKbdType()))
    }

    /// The first layout with a "v" in its Command layer wins.
    static func resolve(layouts: [TISInputSource], keyboardType: UInt32) -> CGKeyCode {
        for layout in layouts {
            if let keyCode = commandV(in: layout, keyboardType: keyboardType) { return keyCode }
        }
        return fallback
    }

    static func commandV(in layout: TISInputSource, keyboardType: UInt32) -> CGKeyCode? {
        guard let property = TISGetInputSourceProperty(layout, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let keyboardLayout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)

        let lowercaseV = UniChar(UnicodeScalar("v").value)
        let uppercaseV = UniChar(UnicodeScalar("V").value)
        for keyCode in UInt16(0)..<128 {
            var deadKeyState: UInt32 = 0
            var output = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(
                keyboardLayout,
                keyCode,
                UInt16(kUCKeyActionDisplay),
                commandModifierState,
                keyboardType,
                OptionBits(kUCKeyTranslateNoDeadKeysMask),
                &deadKeyState,
                output.count,
                &length,
                &output
            )
            if status == noErr, length == 1, output[0] == lowercaseV || output[0] == uppercaseV {
                return keyCode
            }
        }
        return nil
    }
}
