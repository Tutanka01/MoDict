import AppKit
import SwiftUI

/// When each character of the preview appeared and when the recognizer
/// committed to it, so new words can condense out of a blur and tentative
/// words can brighten as they are confirmed.
///
/// The renderer only *draws* from these stamps; the caption's layout is still
/// one deterministic pass per partial, so nothing swims.
struct HUDInk: Equatable {
    struct Stamp: Hashable {
        /// When the character appeared; 0 once its entrance is long over.
        var born: TimeInterval
        /// When it was confirmed; nil while volatile, 0 once its brightening
        /// is long over.
        var lit: TimeInterval?
    }

    struct Segment: Equatable {
        var text: String
        var stamp: Stamp
    }

    private(set) var characters: [Character] = []
    private(set) var stamps: [Stamp] = []
    /// The caret stays solid while words keep arriving.
    private(set) var lastChange: TimeInterval = -.infinity
    /// Character offset where each caption line begins (see `HUDLineBreaker`).
    private(set) var lineStarts: [Int] = [0]

    /// Longer than any entrance: older stamps collapse to 0 so settled text
    /// renders as a few long runs.
    static let settleAfter: TimeInterval = 1.2

    /// Past this many changed characters (both sides together) the diff is not
    /// worth its cost: the rest is new ink. Bounds the work at the moment the
    /// final text replaces a preview from another model.
    private static let maxDiffLength = 1500

    var isEmpty: Bool { characters.isEmpty }
    var text: String { String(characters) }

    /// Keeps the stamps of every word the new text shares with the old one,
    /// wherever it sits; a word the recognizer touched is new ink from its
    /// first letter to its last, so a revision visibly rewrites that word.
    /// Matching only the shared prefix is not enough: the final text often
    /// differs from the preview at its very start (a comma, a capital), and
    /// everything after that would blur away and condense again.
    mutating func update(_ partial: PartialTranscript?, at time: TimeInterval) {
        guard let partial, !partial.isEmpty else {
            self = HUDInk()
            return
        }
        let separator = partial.confirmedText.isEmpty || partial.volatileText.isEmpty ? "" : " "
        let display = Array(partial.confirmedText + separator + partial.volatileText)
        let confirmedCount = partial.confirmedText.count

        let carried = Self.carriedStamps(old: characters, stamps: stamps, new: display)
        var next: [Stamp] = []
        next.reserveCapacity(display.count)
        for index in display.indices {
            var stamp = carried[index] ?? Stamp(born: time, lit: nil)
            if stamp.born > 0, time - stamp.born > Self.settleAfter { stamp.born = 0 }
            if index < confirmedCount {
                if let lit = stamp.lit {
                    if lit > 0, time - lit > Self.settleAfter { stamp.lit = 0 }
                } else {
                    stamp.lit = time
                }
            } else {
                stamp.lit = nil
            }
            next.append(stamp)
        }
        if display != characters {
            lastChange = time
            lineStarts = HUDLineBreaker.lineStarts(of: display)
        }
        characters = display
        stamps = next
    }

    /// The stamp each character of `new` keeps from `old`; nil = new ink.
    private static func carriedStamps(old: [Character], stamps: [Stamp], new: [Character]) -> [Stamp?] {
        var carried = [Stamp?](repeating: nil, count: new.count)
        guard !old.isEmpty else { return carried }

        // Only the middle can differ: strip what both ends share, diff the rest.
        let limit = min(old.count, new.count)
        var head = 0
        while head < limit, old[head] == new[head] { head += 1 }
        var tail = 0
        while tail < limit - head, old[old.count - 1 - tail] == new[new.count - 1 - tail] { tail += 1 }
        for index in 0..<head { carried[index] = stamps[index] }
        for offset in 0..<tail { carried[new.count - 1 - offset] = stamps[old.count - 1 - offset] }

        let oldMiddle = Array(old[head..<(old.count - tail)])
        let newMiddle = Array(new[head..<(new.count - tail)])
        if !oldMiddle.isEmpty, !newMiddle.isEmpty, oldMiddle.count + newMiddle.count <= maxDiffLength {
            var removed = Set<Int>()
            var inserted = Set<Int>()
            for change in newMiddle.difference(from: oldMiddle) {
                switch change {
                case .remove(let offset, _, _): removed.insert(offset)
                case .insert(let offset, _, _): inserted.insert(offset)
                }
            }
            var oldIndex = 0
            for newIndex in newMiddle.indices where !inserted.contains(newIndex) {
                while removed.contains(oldIndex) { oldIndex += 1 }
                carried[head + newIndex] = stamps[head + oldIndex]
                oldIndex += 1
            }
        }

        // A word with any new letter is new ink whole, never half a word.
        var index = 0
        while index < new.count {
            guard isWordCharacter(new[index]) else { index += 1; continue }
            var end = index
            while end < new.count, isWordCharacter(new[end]) { end += 1 }
            if carried[index..<end].contains(where: { $0 == nil }) {
                for touched in index..<end { carried[touched] = nil }
            }
            index = end
        }
        return carried
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "'" || character == "’" || character == "-"
    }

    /// The caption from `first` on, as runs of identically stamped characters,
    /// with the line breaks `HUDLineBreaker` chose written into the text (the
    /// space that ended a line becomes the break). `Text` then never wraps
    /// anything itself, and starting at a line start leaves every later line
    /// exactly as it was, so lines can be dropped from the top invisibly.
    func segments(fromLine first: Int = 0) -> [Segment] {
        guard !characters.isEmpty else { return [] }
        let starts = lineStarts
        let firstLine = min(max(first, 0), starts.count - 1)
        let begin = starts[firstLine]

        var text: [Character] = []
        var marks: [Stamp] = []
        text.reserveCapacity(characters.count - begin + 8)
        marks.reserveCapacity(characters.count - begin + 8)
        var nextLine = firstLine + 1
        for index in begin..<characters.count {
            if nextLine < starts.count, starts[nextLine] == index {
                if let last = text.last, last.isWhitespace {
                    text[text.count - 1] = "\n"
                } else if let stamp = marks.last {
                    text.append("\n")
                    marks.append(stamp)
                }
                nextLine += 1
            }
            text.append(characters[index])
            marks.append(stamps[index])
        }

        var result: [Segment] = []
        for (character, stamp) in zip(text, marks) {
            if let last = result.last, last.stamp == stamp {
                result[result.count - 1].text.append(character)
            } else {
                result.append(Segment(text: String(character), stamp: stamp))
            }
        }
        return result
    }
}

private struct HUDInkAttribute: TextAttribute {
    var stamp: HUDInk.Stamp
}

/// The private preview: your words, ending in a live cursor.
///
/// The card grows with the words, one line at a time, up to three lines; the
/// text then glides up as each new line begins, older lines leaving through a
/// top fade. Nothing is a ScrollView and nothing is measured: the lines are
/// broken by `HUDLineBreaker`, so their count is known before drawing, and
/// `HUDCaptionMotion` springs the card height and the scroll position on the
/// display clock. Only the lines that can still be seen are laid out, cut at a
/// line start, so a long dictation neither costs more nor rewraps.
struct HUDCaption: View {
    let ink: HUDInk
    let settling: Bool
    let voice: HUDVoiceActivity

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var motion = HUDCaptionMotion()

    var body: some View {
        let lineCount = ink.lineStarts.count
        let scrollTarget = CGFloat(max(0, lineCount - Theme.hudPreviewMaxLines))
        let linesTarget = CGFloat(min(lineCount, Theme.hudPreviewMaxLines))
        let first = firstLine(scrollTarget: scrollTarget, linesTarget: linesTarget)
        let text = Self.text(for: ink.segments(fromLine: first))

        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let _ = motion.advance(scroll: scrollTarget, lines: linesTarget, at: time, animated: !reduceMotion)
            let lines = min(max(motion.lines, 1), CGFloat(Theme.hudPreviewMaxLines))
            let viewport = lines * Theme.hudPreviewLinePitch - Theme.hudPreviewLineSpacing
            let scrolled = max(0, motion.scroll - CGFloat(first)) * Theme.hudPreviewLinePitch

            text
                .font(Theme.hudPreviewFont)
                .lineSpacing(Theme.hudPreviewLineSpacing)
                .foregroundStyle(Color.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textRenderer(renderer(at: time))
                .offset(y: -scrolled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: viewport, alignment: .top)
                .clipped()
                .mask { Self.topFade(scroll: motion.scroll) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Dictation preview")
        .accessibilityValue(Text(verbatim: ink.text))
    }

    /// The first line to lay out: the one at the top of the view, less one
    /// spare line so a retreating scroll (a revision that shortens the text)
    /// never uncovers blank space. Everything above it is out of sight.
    private func firstLine(scrollTarget: CGFloat, linesTarget: CGFloat) -> Int {
        // A preview that first appears already long starts at rest on its tail.
        if !motion.isPrimed { motion.prime(scroll: scrollTarget, lines: linesTarget) }
        return max(0, Int(min(motion.scroll, scrollTarget).rounded(.down)) - 1)
    }

    /// Fades the oldest line out as the text scrolls, in step with the glide:
    /// nothing while everything fits, the full fade once a line has left.
    private static func topFade(scroll: CGFloat) -> LinearGradient {
        let amount = min(max(scroll, 0), 1)
        let eased = amount * amount * (3 - 2 * amount)
        return LinearGradient(
            stops: [
                .init(color: .black.opacity(1 - eased), location: 0),
                .init(color: .black.opacity(1 - 0.45 * eased), location: 0.16),
                .init(color: .black, location: 0.45),
                .init(color: .black, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func renderer(at time: TimeInterval) -> HUDCaptionRenderer {
        let activity = max(voice.lastVoiceTime, ink.lastChange)
        let caret = HUDVoiceActivity.caretOpacity(at: time, lastActivity: activity,
                                                  settling: settling, reduceMotion: reduceMotion)
        let phase = time.truncatingRemainder(dividingBy: HUDCaptionRenderer.settlePeriod)
            / HUDCaptionRenderer.settlePeriod
        return HUDCaptionRenderer(
            time: time,
            settlePhase: settling ? (reduceMotion ? nil : phase) : nil,
            settled: settling,
            caretOpacity: caret,
            animated: !reduceMotion
        )
    }

    /// One Text built from stamped runs. The cursor is not part of it: it is
    /// drawn after the last glyph, so it can never pull a word onto the next
    /// line and back as the words arrive.
    private static func text(for segments: [HUDInk.Segment]) -> Text {
        var text = Text(verbatim: "")
        for segment in segments {
            let run = Text(verbatim: segment.text).customAttribute(HUDInkAttribute(stamp: segment.stamp))
            text = Text("\(text)\(run)")
        }
        return text
    }
}

/// Draws the caption's ink: new glyphs condense out of a blur and rise into
/// place one after another, tentative words sit dimmer and brighten when
/// confirmed, a soft light sweeps the words while the final text is prepared,
/// and the caret rides the front of the ink. Drawing only, never layout.
struct HUDCaptionRenderer: TextRenderer {
    var time: TimeInterval
    /// 0…1 position of the settling sweep; nil when not sweeping.
    var settlePhase: Double?
    /// After release: the words dim slightly under the sweep.
    var settled: Bool
    var caretOpacity: Double
    var animated: Bool

    static let settlePeriod: TimeInterval = 1.6
    static let entrance: TimeInterval = 0.5
    static let stagger: TimeInterval = 0.018
    /// A whole revised sentence still arrives within this long.
    static let maxCascade: TimeInterval = 0.45
    static let brighten: TimeInterval = 0.35
    static let confirmedOpacity = 0.95
    static let volatileOpacity = 0.5
    /// After release every word is about to be final: none may look lost.
    static let settlingFloor = 0.72

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let cascade = cascadeSizes(layout)
        let front: InkFront?
        if settled {
            var dimmed = context
            dimmed.opacity *= Self.settlingFloor
            front = drawInk(layout, cascade: cascade, in: &dimmed)
            if let phase = settlePhase, let band = sweepBand(layout, phase: phase) {
                var highlight = context
                highlight.clipToLayer { layer in
                    layer.fill(Path(band), with: .linearGradient(
                        Gradient(colors: [.clear, .white, .clear]),
                        startPoint: CGPoint(x: band.minX, y: 0),
                        endPoint: CGPoint(x: band.maxX, y: 0)
                    ))
                }
                _ = drawInk(layout, cascade: cascade, in: &highlight)
            }
        } else {
            front = drawInk(layout, cascade: cascade, in: &context)
        }
        drawCaret(front: front, in: &context)
    }

    /// Where the caret sits: on the ink front.
    private enum InkFront {
        /// After the last glyph already visible (all of them, once they have landed).
        case after(CGRect)
        /// Before the first glyph: nothing has landed yet.
        case before(CGRect)
    }

    /// Draws every glyph and returns the ink front. The caret rides that
    /// front, so the words appear to be typed by your voice instead of the
    /// caret leaping ahead of them.
    private func drawInk(_ layout: Text.Layout, cascade: [TimeInterval: Int],
                         in context: inout GraphicsContext) -> InkFront? {
        var drawn: [TimeInterval: Int] = [:]
        var front: InkFront?
        func reach(_ rect: CGRect, visible: Bool) {
            if visible {
                front = .after(rect)
            } else if front == nil {
                front = .before(rect)
            }
        }
        for line in layout {
            for run in line {
                let stamp = run[HUDInkAttribute.self]?.stamp ?? HUDInk.Stamp(born: 0, lit: 0)
                let brightness = brightness(stamp)
                guard animated, stamp.born > 0, time - stamp.born < Self.entrance + Self.maxCascade else {
                    var plain = context
                    plain.opacity *= brightness
                    plain.draw(run)
                    if let last = run.last { reach(last.typographicBounds.rect, visible: true) }
                    continue
                }
                let total = cascade[stamp.born] ?? run.count
                let step = min(Self.stagger, Self.maxCascade / Double(max(total, 1)))
                var index = drawn[stamp.born] ?? 0
                for slice in run {
                    let progress = (time - stamp.born - Double(index) * step) / Self.entrance
                    index += 1
                    reach(slice.typographicBounds.rect, visible: progress > 0.3)
                    guard progress > 0 else { continue }
                    var glyph = context
                    if progress >= 1 {
                        glyph.opacity *= brightness
                    } else {
                        let eased = 1 - pow(1 - progress, 3)
                        glyph.opacity *= brightness * eased
                        glyph.translateBy(x: 0, y: CGFloat(1 - eased) * 3.5)
                        if eased < 0.97 { glyph.addFilter(.blur(radius: CGFloat(1 - eased) * 5)) }
                    }
                    glyph.draw(slice)
                }
                drawn[stamp.born] = index
            }
        }
        return front
    }

    private func brightness(_ stamp: HUDInk.Stamp) -> Double {
        // Settling: tentative words rise to the confirmed level, then the
        // whole caption sits under one even floor.
        if settled { return Self.confirmedOpacity }
        guard let lit = stamp.lit else { return Self.volatileOpacity }
        guard animated, lit > 0 else { return Self.confirmedOpacity }
        let progress = min(1, max(0, (time - lit) / Self.brighten))
        let eased = progress * progress * (3 - 2 * progress)
        return Self.volatileOpacity + (Self.confirmedOpacity - Self.volatileOpacity) * eased
    }

    /// Glyph counts per entrance, so a batch that wraps across lines keeps
    /// one left-to-right cascade.
    private func cascadeSizes(_ layout: Text.Layout) -> [TimeInterval: Int] {
        guard animated else { return [:] }
        var sizes: [TimeInterval: Int] = [:]
        for line in layout {
            for run in line {
                guard let born = run[HUDInkAttribute.self]?.stamp.born, born > 0 else { continue }
                sizes[born, default: 0] += run.count
            }
        }
        return sizes
    }

    private func sweepBand(_ layout: Text.Layout, phase: Double) -> CGRect? {
        var bounds = CGRect.null
        for line in layout { bounds = bounds.union(line.typographicBounds.rect) }
        guard !bounds.isNull, bounds.width > 0 else { return nil }
        let width = max(90, bounds.width * 0.45)
        let x = bounds.minX - width + (bounds.width + width) * phase
        return CGRect(x: x, y: bounds.minY, width: width, height: bounds.height)
    }

    /// One space after the last visible glyph, or at the first glyph while
    /// nothing has landed. Kept inside the caption's column when a line is full.
    private func drawCaret(front: InkFront?, in context: inout GraphicsContext) {
        guard let front else { return }
        let x: CGFloat
        let rect: CGRect
        switch front {
        case .after(let glyph):
            x = min(glyph.maxX + Self.spaceWidth, Theme.hudCaptionWrapWidth - 1)
            rect = glyph
        case .before(let glyph):
            x = glyph.minX - 0.5   // the caption clips anything left of 0
            rect = glyph
        }
        let height = min(Theme.caretHeight, rect.height)
        let caret = CGRect(x: x + 0.5, y: rect.midY - height / 2, width: Theme.caretWidth, height: height)
        HUDCaretMark.draw(in: &context, rect: caret, opacity: caretOpacity)
    }

    /// The width of a space in the preview font.
    private static let spaceWidth: CGFloat = {
        (" " as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: Theme.hudPreviewFontSize)]).width
    }()
}
