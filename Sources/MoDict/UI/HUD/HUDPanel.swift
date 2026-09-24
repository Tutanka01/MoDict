import AppKit
import SwiftUI

/// Borderless, non-activating panel that hosts the composition preview.
///
/// It must never become key or main: MoDict inserts text at the cursor of
/// whatever app is focused, so stealing focus — even for an instant — would
/// break insertion. `.statusBar` level keeps the card above normal windows,
/// and the collection behavior lets it float over every Space and full-screen app.
///
/// The HUD carries one constant identity, like Apple's volume and brightness
/// overlays: it always renders dark, whatever appearance the system — or the
/// app behind it — uses. A light translucent surface dissolves over a black
/// terminal; a dark HUD reads everywhere.
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

        // Constant dark identity for the card's materials and `Color.primary`
        // foregrounds (see the class comment). Apple's own overlays never flip
        // with system appearance either.
        appearance = NSAppearance(named: .darkAqua)

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

/// The HUD surface on macOS 15: AppKit's own heads-up-display material — the
/// same `hudWindow` recipe behind Apple's volume and brightness overlays. It
/// stays legible over any content (white pages, black terminals) and AppKit
/// swaps it for an opaque fill under Reduce Transparency automatically.
///
/// macOS 26+ instead renders Liquid Glass via `glassEffect` in HUDView.
struct HUDMaterial: NSViewRepresentable {
    var cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        // The panel can never become key or main; force the active look so the
        // material never renders in its muted inactive state.
        view.state = .active
        view.maskImage = Self.maskImage(cornerRadius: cornerRadius)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}

    /// Nine-patch rounded-rect mask: the corner region stretches so the
    /// window-server-composited backdrop is clipped to smooth antialiased
    /// corners — the recipe Apple documents for volume-like HUD windows.
    private static func maskImage(cornerRadius: CGFloat) -> NSImage {
        let length = cornerRadius * 2 + 1
        let image = NSImage(size: NSSize(width: length, height: length), flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(
            top: cornerRadius, left: cornerRadius, bottom: cornerRadius, right: cornerRadius
        )
        image.resizingMode = .stretch
        return image
    }
}
