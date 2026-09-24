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

    /// Longer than any entrance: older stamps collapse to 0 so settled text
    /// renders as a few long runs.
    static let settleAfter: TimeInterval = 1.2

    var isEmpty: Bool { characters.isEmpty }
    var text: String { String(characters) }

    /// Keeps the stamps of the unchanged prefix; everything after the first
    /// difference is new ink. A revised word therefore re-condenses, which is
    /// exactly what happened: the recognizer changed its mind.
    mutating func update(_ partial: PartialTranscript?, at time: TimeInterval) {
        guard let partial, !partial.isEmpty else {
            self = HUDInk()
            return
        }
        let separator = partial.confirmedText.isEmpty || partial.volatileText.isEmpty ? "" : " "
        let display = Array(partial.confirmedText + separator + partial.volatileText)
        let confirmedCount = partial.confirmedText.count

        var shared = 0
        let limit = min(characters.count, display.count)
        while shared < limit, characters[shared] == display[shared] { shared += 1 }

        var next: [Stamp] = []
        next.reserveCapacity(display.count)
        for index in display.indices {
            var stamp = index < shared ? stamps[index] : Stamp(born: time, lit: nil)
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
        if display != characters { lastChange = time }
        characters = display
        stamps = next
    }

    /// The recent tail (the three-line window can never show more), as runs
    /// of identically stamped characters. Cut on a word boundary so no half
    /// word surfaces under the fade, and bounded so layout cost stays flat
    /// over a long dictation.
    func segments(limit: Int = 220) -> [Segment] {
        guard !characters.isEmpty else { return [] }
        var start = max(0, characters.count - limit)
        if start > 0, let space = characters[start...].firstIndex(where: \.isWhitespace),
           space + 1 < characters.count {
            start = space + 1
        }
        var result: [Segment] = []
        for index in start..<characters.count {
            if let last = result.last, last.stamp == stamps[index] {
                result[result.count - 1].text.append(characters[index])
            } else {
                result.append(Segment(text: String(characters[index]), stamp: stamps[index]))
            }
        }
        return result
    }
}

private struct HUDInkAttribute: TextAttribute {
    var stamp: HUDInk.Stamp
}

/// Marks the placeholder the renderer replaces with the live caret.
private struct HUDCaretAttribute: TextAttribute {}

/// The private preview: your words, ending in a live cursor.
///
/// The card grows with the words, one line at a time, up to three lines; the
/// text then glides up as each new line wraps, older lines leaving through a
/// top fade. Nothing is a ScrollView: the text is top-pinned and offset by
/// its measured overflow, so there is no scroll position to steer and a
/// partial arriving mid-glide simply retargets the spring.
struct HUDCaption: View {
    let ink: HUDInk
    let settling: Bool
    let voice: HUDVoiceActivity

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var textHeight: CGFloat = 0

    var body: some View {
        let maxHeight = Theme.hudPreviewHeight
        let overflow = max(0, textHeight - maxHeight)
        let viewport = min(max(textHeight, Theme.hudPreviewLineHeight), maxHeight)
        let text = Self.text(for: ink.segments())

        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion)) { context in
            text
                .font(Theme.hudPreviewFont)
                .lineSpacing(Theme.hudPreviewLineSpacing)
                .foregroundStyle(Color.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textRenderer(renderer(at: context.date.timeIntervalSinceReferenceDate))
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            withAnimation(reduceMotion ? nil : Theme.captionSpring) { textHeight = height }
        }
        .offset(y: -overflow)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: viewport, alignment: .top)
        .clipped()
        .mask {
            ZStack {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black.opacity(0.55), location: 0.16),
                        .init(color: .black, location: 0.45),
                        .init(color: .black, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                // Opaque until the text overflows, so the fade eases in with
                // the first glide instead of snapping.
                Color.black.opacity(overflow > 0.5 ? 0 : 1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Dictation preview")
        .accessibilityValue(Text(verbatim: ink.text))
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

    /// One Text built from stamped runs plus the caret placeholder, glued to
    /// the last word by a no-break space so it never wraps alone.
    private static func text(for segments: [HUDInk.Segment]) -> Text {
        var text = Text(verbatim: "")
        for segment in segments {
            let run = Text(verbatim: segment.text).customAttribute(HUDInkAttribute(stamp: segment.stamp))
            text = Text("\(text)\(run)")
        }
        let caret = Text(verbatim: "\u{00A0}|").customAttribute(HUDCaretAttribute())
        return Text("\(text)\(caret)")
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
        drawCaret(layout, front: front, in: &context)
    }

    /// Where the caret rides while ink is still arriving.
    private enum InkFront {
        /// After the last glyph already visible.
        case after(CGRect)
        /// Before the first glyph: nothing has landed yet.
        case before(CGRect)
    }

    /// Draws every glyph and returns the ink front while later glyphs are
    /// still arriving (nil once all have landed). The caret rides that
    /// front, so the words appear to be typed by your voice instead of the
    /// caret leaping ahead of them.
    private func drawInk(_ layout: Text.Layout, cascade: [TimeInterval: Int],
                         in context: inout GraphicsContext) -> InkFront? {
        var drawn: [TimeInterval: Int] = [:]
        var front: InkFront?
        var pending = false
        func reach(_ rect: CGRect, visible: Bool) {
            if visible {
                front = .after(rect)
                pending = false
            } else {
                if front == nil { front = .before(rect) }
                pending = true
            }
        }
        for line in layout {
            for run in line where run[HUDCaretAttribute.self] == nil {
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
        return pending ? front : nil
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

    /// At the placeholder once the ink has landed, otherwise one no-break
    /// space after the ink front.
    private func drawCaret(_ layout: Text.Layout, front: InkFront?, in context: inout GraphicsContext) {
        for line in layout {
            for run in line where run[HUDCaretAttribute.self] != nil {
                guard let space = run.first, let glyph = run.last else { continue }
                let bounds = glyph.typographicBounds.rect
                var x = bounds.minX
                var midY = bounds.midY
                switch front {
                case .after(let rect):
                    x = rect.maxX + space.typographicBounds.rect.width
                    midY = rect.midY
                case .before(let rect):
                    x = rect.minX - 0.5   // the caption clips anything left of 0
                    midY = rect.midY
                case nil:
                    break
                }
                let height = min(Theme.caretHeight, bounds.height)
                let rect = CGRect(x: x + 0.5, y: midY - height / 2, width: Theme.caretWidth, height: height)
                HUDCaretMark.draw(in: &context, rect: rect, opacity: caretOpacity)
            }
        }
    }
}
