import AppKit
import SwiftUI

/// MoDict's mark: a voice waveform whose peak is a text cursor (I-beam).
/// Your voice goes in, your words come out where the cursor is: the whole
/// product in one shape.
///
/// The geometry is the single source of truth for the in-app glyph and the
/// menu bar image. `Support/generate-icon.swift` and the layers in
/// `Support/AppIcon.icon` reproduce the same proportions; keep them in sync.
struct MoDictMark: Shape {
    /// Proportions relative to the side of the square the mark is drawn in.
    enum Proportion {
        static let barWidth: CGFloat = 0.11
        static let gap: CGFloat = 0.075
        static let outerBarHeight: CGFloat = 0.30
        static let innerBarHeight: CGFloat = 0.56
        static let cursorHeight: CGFloat = 0.86
        static let cursorStem: CGFloat = 0.075
        static let cursorSerifWidth: CGFloat = 0.23
        static let cursorSerifThickness: CGFloat = 0.075
    }

    func path(in rect: CGRect) -> Path {
        Path(Self.cgPath(in: rect))
    }

    /// Vertically symmetric, so it draws identically in flipped (SwiftUI) and
    /// unflipped (AppKit, Core Graphics) coordinate spaces.
    static func cgPath(in rect: CGRect) -> CGPath {
        typealias P = Proportion
        let side = min(rect.width, rect.height)
        let path = CGMutablePath()
        let barWidth = P.barWidth * side
        let gap = P.gap * side
        let serifWidth = P.cursorSerifWidth * side
        let total = 4 * barWidth + serifWidth + 4 * gap
        var x = rect.midX - total / 2

        func capsule(_ frame: CGRect) {
            let radius = min(frame.width, frame.height) / 2
            path.addRoundedRect(in: frame, cornerWidth: radius, cornerHeight: radius)
        }
        func bar(_ height: CGFloat) {
            let height = height * side
            capsule(CGRect(x: x, y: rect.midY - height / 2, width: barWidth, height: height))
            x += barWidth + gap
        }

        bar(P.outerBarHeight)
        bar(P.innerBarHeight)

        let cursorHeight = P.cursorHeight * side
        let stem = P.cursorStem * side
        let serif = P.cursorSerifThickness * side
        let centerX = x + serifWidth / 2
        let bottom = rect.midY - cursorHeight / 2
        capsule(CGRect(x: centerX - stem / 2, y: bottom, width: stem, height: cursorHeight))
        capsule(CGRect(x: centerX - serifWidth / 2, y: bottom, width: serifWidth, height: serif))
        capsule(CGRect(x: centerX - serifWidth / 2, y: bottom + cursorHeight - serif,
                       width: serifWidth, height: serif))
        x += serifWidth + gap

        bar(P.innerBarHeight)
        bar(P.outerBarHeight)
        return path
    }
}

/// The same mark across setup, settings, and the menu: the mark knocked out
/// of a solid tile, echoing the app icon.
struct AppGlyph: View {
    var size: CGFloat = 40

    var body: some View {
        MoDictMark()
            .fill(.background)
            .frame(width: size * 0.62, height: size * 0.62)
            .frame(width: size, height: size)
            .background(.primary, in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Template images for the status item. Drawn from the mark so the menu bar,
/// the app icon and every in-app glyph share one silhouette.
enum MenuBarGlyph {
    case idle
    /// Recording or transcribing: the mark knocked out of a solid tile.
    case active
    /// Dictation paused: the mark, dimmed.
    case paused

    var image: NSImage {
        switch self {
        case .idle: Self.idleImage
        case .active: Self.activeImage
        case .paused: Self.pausedImage
        }
    }

    private static let size = NSSize(width: 18, height: 16)

    private static let idleImage = template { rect in
        fill(MoDictMark.cgPath(in: rect.insetBy(dx: 0.5, dy: 0)), alpha: 1)
    }

    private static let pausedImage = template { rect in
        fill(MoDictMark.cgPath(in: rect.insetBy(dx: 0.5, dy: 0)), alpha: 0.4)
    }

    private static let activeImage = template { rect in
        let tile = CGRect(x: rect.midX - 8, y: rect.midY - 8, width: 16, height: 16)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.addPath(CGPath(roundedRect: tile, cornerWidth: 4.5, cornerHeight: 4.5, transform: nil))
        context.setFillColor(NSColor.black.cgColor)
        context.fillPath()
        // Punch the mark out (non-zero fill: its overlapping cursor parts
        // would re-fill under an even-odd rule).
        context.setBlendMode(.clear)
        context.addPath(MoDictMark.cgPath(in: tile.insetBy(dx: 3, dy: 3)))
        context.fillPath()
    }

    private static func fill(_ path: CGPath, alpha: CGFloat) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.addPath(path)
        context.setFillColor(NSColor.black.withAlphaComponent(alpha).cgColor)
        context.fillPath()
    }

    private static func template(_ draw: @escaping (CGRect) -> Void) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            draw(rect)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "MoDict"
        return image
    }
}
