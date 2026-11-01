import Carbon
import Testing
@testable import MoDict

/// Runs against the layouts macOS ships; only translates keys, never posts them.
@MainActor
struct PasteKeyResolverTests {
    @Test(arguments: [
        ("com.apple.keylayout.Dvorak", 47),
        ("com.apple.keylayout.Turkish", 8),
        ("com.apple.keylayout.ABC", 9),
        ("com.apple.keylayout.French", 9),
        ("com.apple.keylayout.DVORAK-QWERTYCMD", 9),
        ("com.apple.keylayout.Russian", 9)
    ] as [(String, Int)])
    func commandLayerResolvesTheRealPasteKey(layoutID: String, expected: Int) throws {
        guard let layout = Self.layout(layoutID) else {
            print("Skipping \(layoutID): not installed")
            return
        }
        #expect(PasteKeyResolver.resolve(layouts: [layout], keyboardType: Self.keyboardType) == CGKeyCode(expected))
    }

    @Test
    func theFirstLayoutWithAVWins() throws {
        guard let dvorak = Self.layout("com.apple.keylayout.Dvorak"),
              let abc = Self.layout("com.apple.keylayout.ABC") else { return }
        #expect(PasteKeyResolver.resolve(layouts: [dvorak, abc], keyboardType: Self.keyboardType) == 47)
        #expect(PasteKeyResolver.resolve(layouts: [abc, dvorak], keyboardType: Self.keyboardType) == 9)
    }

    @Test
    func noLayoutFallsBackToKeyCodeNine() {
        #expect(PasteKeyResolver.resolve(layouts: [], keyboardType: Self.keyboardType) == 9)
    }

    @Test
    func resolvedKeyGoesIntoTheEventsWithCommandHeld() throws {
        let events = try #require(TextInserter.pasteEvents(virtualKey: 47))
        let codes = events.map { $0.getIntegerValueField(.keyboardEventKeycode) }
        #expect(codes == [0x37, 47, 47, 0x37])
        #expect(events[1].flags.contains(.maskCommand))
        #expect(events[2].flags.contains(.maskCommand))
        #expect(!events[3].flags.contains(.maskCommand))
    }

    private static var keyboardType: UInt32 { UInt32(LMGetKbdType()) }

    private static func layout(_ id: String) -> TISInputSource? {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource] else {
            return nil
        }
        return list.first
    }
}
