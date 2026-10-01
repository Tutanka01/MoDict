import AppKit
import CoreText

/// Breaks the caption into lines itself, at one fixed width.
///
/// Greedy line breaking has one property everything here leans on: once a line
/// starts at a given word, every later break is the same whatever came before.
/// Breaking the text ourselves (instead of letting `Text` wrap it) therefore
/// gives lines that never rewrap as words arrive, and lets the caption drop
/// whole lines from the top without moving a single visible word. It also tells
/// the caption how many lines it has before anything is drawn, so nothing has
/// to be measured after layout.
enum HUDLineBreaker {
    /// Character offset where each line begins; the first is always 0.
    static func lineStarts(of characters: [Character],
                           width: CGFloat = Theme.hudCaptionWrapWidth) -> [Int] {
        guard !characters.isEmpty else { return [0] }
        let attributed = NSAttributedString(
            string: String(characters),
            attributes: [.font: NSFont.systemFont(ofSize: Theme.hudPreviewFontSize)]
        )
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let length = attributed.length

        // The typesetter counts UTF-16 units.
        var breaks: [Int] = []
        var location = 0
        while location < length {
            let count = CTTypesetterSuggestLineBreak(typesetter, location, Double(width))
            guard count > 0 else { break }
            location += count
            if location < length { breaks.append(location) }
        }

        var starts = [0]
        var pending = breaks.makeIterator()
        var nextBreak = pending.next()
        var offset = 0
        for (index, character) in characters.enumerated() {
            while let target = nextBreak, target <= offset {
                if target == offset, index > 0 { starts.append(index) }
                nextBreak = pending.next()
            }
            offset += character.utf16.count
        }
        return starts
    }
}

/// The caption's two motions, on the display clock: how many lines the card
/// shows (it grows one line at a time up to three) and how far the text has
/// scrolled past the top.
///
/// Both are critically damped springs integrated in closed form each frame,
/// like `HUDLevelSmoother` for the bars. Nothing here goes through SwiftUI's
/// animation system, which is what made the whole text jolt sideways for a
/// frame at the start of every glide: an animated transaction was also reaching
/// the text. A partial arriving mid-glide only moves the target; position and
/// velocity carry on, so the motion never restarts.
///
/// Units are lines, not points: the scroll position is absolute (lines since
/// the dictation began), so dropping lines from the top of the laid-out text
/// changes nothing on screen.
final class HUDCaptionMotion {
    /// Lines scrolled past the top; 0 while everything fits.
    private(set) var scroll: CGFloat = 0
    /// Lines showing, 1…3: the card's height.
    private(set) var lines: CGFloat = 1

    private var scrollVelocity: CGFloat = 0
    private var linesVelocity: CGFloat = 0
    private var lastTime: TimeInterval?
    private(set) var isPrimed = false

    /// A soft glide: about 0.4 s to cover 90% of a line.
    static let scrollResponse: TimeInterval = 0.62
    /// The card grows a little quicker than the text glides.
    static let growResponse: TimeInterval = 0.45

    /// Starts at rest on the targets, so a preview that first appears already
    /// long (a batch model's whole text) never glides in from nothing.
    func prime(scroll: CGFloat, lines: CGFloat) {
        self.scroll = scroll
        self.lines = lines
        scrollVelocity = 0
        linesVelocity = 0
        isPrimed = true
    }

    func advance(scroll scrollTarget: CGFloat, lines linesTarget: CGFloat,
                 at time: TimeInterval, animated: Bool) {
        defer { lastTime = time }
        guard animated, isPrimed else {
            prime(scroll: scrollTarget, lines: linesTarget)
            return
        }
        // A long gap (first frame, a paused timeline) must not teleport the text.
        let dt = lastTime.map { min(max(time - $0, 0), 0.05) } ?? 0
        Self.step(&scroll, &scrollVelocity, toward: scrollTarget, response: Self.scrollResponse, dt: dt)
        Self.step(&lines, &linesVelocity, toward: linesTarget, response: Self.growResponse, dt: dt)
    }

    /// Exact solution of a critically damped spring over `dt`, for a target
    /// that held still during the step.
    static func step(_ value: inout CGFloat, _ velocity: inout CGFloat,
                     toward target: CGFloat, response: TimeInterval, dt: TimeInterval) {
        let omega = CGFloat(2 * Double.pi / response)
        let offset = value - target
        if abs(offset) < 0.0005, abs(velocity) < 0.0005 {
            value = target
            velocity = 0
            return
        }
        let t = CGFloat(dt)
        let carried = velocity + omega * offset
        let decay = CGFloat(exp(-Double(omega * t)))
        value = target + (offset + carried * t) * decay
        velocity = (velocity - omega * carried * t) * decay
    }
}
