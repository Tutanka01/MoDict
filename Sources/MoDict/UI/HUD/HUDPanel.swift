import AppKit

/// Borderless, non-activating panel that hosts the composition preview.
///
/// It must never become key or main: MoDict inserts text at the cursor of
/// whatever app is focused, so stealing focus — even for an instant — would
/// break insertion. `.statusBar` level keeps the card above normal windows,
/// and the collection behavior lets it float over every Space and full-screen app.
final class HUDPanel: NSPanel {

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false

        // The card, its hairline and its shadow are all drawn in SwiftUI, so the
        // window itself is fully transparent and casts no AppKit shadow.
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false

        // Purely indicative: never intercept clicks meant for the app underneath.
        ignoresMouseEvents = true
        isMovableByWindowBackground = false
        isMovable = false

        titleVisibility = .hidden
        titlebarAppearsTransparent = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
