import CoreGraphics

/// Tells MoDict's own posted keystrokes apart from the user's. Set `marker` as the
/// `userData` of the `CGEventSource` behind every event MoDict posts: the hotkey taps
/// skip those, so a synthetic ⌘V can never read as a chord against the trigger key.
enum SyntheticEvents {
    static let marker: Int64 = 0x4D6F_4469_6374   // "MoDict"

    static func isOwn(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == marker
    }
}
