import SwiftUI

/// When your voice was last heard, and when the HUD stopped listening. The
/// caret reads it like a caret reads typing: solid while you speak, blinking
/// again after a pause.
///
/// Advanced once per display frame by `HUDVoicePrint`; a reference type for
/// the same reason as `HUDLevelSmoother`: per-frame state must not re-render
/// the card.
final class HUDVoiceActivity {
    /// A level above this counts as voice: it holds the caret solid.
    static let voiceThreshold: CGFloat = 0.08

    /// When the voice was last heard.
    private(set) var lastVoiceTime: TimeInterval = -.infinity
    /// When listening stopped (release): the bars ease into the transcribing
    /// ripple from here instead of snapping.
    private(set) var settleStart: TimeInterval?

    func advance(to time: TimeInterval, level: CGFloat, listening: Bool) {
        guard listening else {
            if settleStart == nil { settleStart = time }
            return
        }
        settleStart = nil
        if level >= Self.voiceThreshold { lastVoiceTime = time }
    }

    func reset() {
        lastVoiceTime = -.infinity
        settleStart = nil
    }

    /// Caret opacity: solid while you speak, a native caret blink at rest
    /// (on, quick fade, off), and a slow breath while the text is prepared.
    static func caretOpacity(at time: TimeInterval, lastActivity: TimeInterval,
                             settling: Bool, reduceMotion: Bool) -> Double {
        if reduceMotion { return 1 }
        if settling {
            return 0.45 + 0.55 * (0.5 + 0.5 * cos(time * 2 * .pi / 1.4))
        }
        let idle = time - lastActivity
        guard idle > 0.5 else { return 1 }
        let phase = (idle - 0.5).truncatingRemainder(dividingBy: Theme.caretBlinkPeriod) / Theme.caretBlinkPeriod
        // A cosine sharpened into plateaus: long on, long off, soft edges.
        let wave = 0.5 + 0.5 * cos(phase * 2 * .pi)
        return min(1, max(0, (wave - 0.5) * 3.2 + 0.5))
    }
}

/// The living mark: the voice waveform beside a text cursor, MoDict's logo in
/// motion. The capsule shows both; once words exist the cursor moves into the
/// text (`HUDCaption`) and the waveform remains as the microphone meter.
///
/// Drawn in one `Canvas` on the display clock: every frame is a redraw only,
/// never a layout pass.
struct HUDVoicePrint: View, Animatable {
    let voice: HUDVoiceActivity
    let level: HUDLevelSmoother
    let settling: Bool
    /// 1 in the capsule, 0 once the cursor lives in the text; animated so the
    /// cursor fades as the card grows.
    var caretPresence: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var animatableData: CGFloat {
        get { caretPresence }
        set { caretPresence = newValue }
    }

    static let waveformWidth = CGFloat(Theme.waveformBarCount) * Theme.waveformBarWidth
        + CGFloat(Theme.waveformBarCount - 1) * Theme.waveformBarGap
    static let width = waveformWidth + Theme.caretGap + Theme.caretWidth

    var body: some View {
        // Reduce Motion: a slow level read, no wobble, no blink.
        TimelineView(.animation(minimumInterval: reduceMotion ? 0.2 : nil)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let current = level.value(at: t)
            let _ = voice.advance(to: t, level: current, listening: !settling)
            Canvas { canvas, size in
                drawWaveform(in: &canvas, size: size, t: t, level: current)
                if caretPresence > 0.01 {
                    drawCaret(in: &canvas, size: size, t: t)
                }
            }
        }
        .frame(width: Self.width, height: Theme.hudRowHeight)
        .accessibilityHidden(true)
    }

    private func drawWaveform(in canvas: inout GraphicsContext, size: CGSize, t: TimeInterval, level: CGFloat) {
        let count = Theme.waveformBarCount
        let minH = Theme.waveformBarMinHeight
        let maxH = Theme.waveformBarMaxHeight
        let settle = reduceMotion ? 0 : settleBlend(t)
        // Reduce Motion freezes the wobble and the breath at their t = 0 pose.
        let motionTime = reduceMotion ? 0 : t
        let input = reduceMotion && settling ? 0 : level

        for index in 0..<count {
            var height = Self.barHeight(index, level: input, t: motionTime)
            if settle > 0 {
                // A soft wave running toward the cursor: the text is on its way.
                let age = Double(count - 1 - index)
                let wave = 0.5 + 0.5 * sin(age * 0.8 + t * 7.0)
                let ripple = minH + (maxH - minH) * 0.3 * CGFloat(wave) * Self.shape[index]
                height += (ripple - height) * settle
            }
            let x = CGFloat(index) * (Theme.waveformBarWidth + Theme.waveformBarGap)
            let rect = CGRect(x: x, y: (size.height - height) / 2,
                              width: Theme.waveformBarWidth, height: height)
            canvas.fill(Capsule().path(in: rect), with: .color(.primary.opacity(0.88)))
        }
    }

    private static let shape: [CGFloat] = [0.50, 0.72, 0.90, 1.00, 0.90, 0.72, 0.50]
    private static let phase: [Double] = [0.0, 0.8, 1.7, 2.5, 3.4, 4.2, 5.1]
    private static let speed: [Double] = [8.2, 9.1, 7.6, 8.8, 7.9, 9.4, 8.0]

    /// An arch that wobbles with your voice and breathes slowly in silence.
    private static func barHeight(_ index: Int, level: CGFloat, t: TimeInterval) -> CGFloat {
        let minHeight = Theme.waveformBarMinHeight
        let maxHeight = Theme.waveformBarMaxHeight
        let shape = Self.shape[index]

        if level < 0.03 {
            let breath = 0.5 + 0.5 * sin(t * 1.05 + Self.phase[index])
            return minHeight + 1.1 * CGFloat(breath) * shape
        }

        let wobble = 0.55 + 0.45 * (0.5 + 0.5 * sin(t * Self.speed[index] + Self.phase[index]))
        let amplitude = min(1, level * shape * CGFloat(wobble))
        return minHeight + (maxHeight - minHeight) * amplitude
    }

    private func drawCaret(in canvas: inout GraphicsContext, size: CGSize, t: TimeInterval) {
        let blink = HUDVoiceActivity.caretOpacity(at: t, lastActivity: voice.lastVoiceTime,
                                                  settling: settling, reduceMotion: reduceMotion)
        let x = Self.waveformWidth + Theme.caretGap
        let height = Theme.caretHeight
        let rect = CGRect(x: x, y: (size.height - height) / 2, width: Theme.caretWidth, height: height)
        HUDCaretMark.draw(in: &canvas, rect: rect, opacity: blink * Double(caretPresence))
    }

    /// 0 while listening, easing to 1 over 0.4 s after release.
    private func settleBlend(_ t: TimeInterval) -> CGFloat {
        guard settling, let start = voice.settleStart else { return 0 }
        let x = min(1, max(0, (t - start) / 0.4))
        return CGFloat(x * x * (3 - 2 * x))
    }
}

/// The text cursor drawn by the HUD, in the capsule and at the end of the
/// preview: one shape, one rhythm. It needs no glow to show it hears you:
/// like a real caret while you type, it simply stops blinking.
enum HUDCaretMark {
    static func draw(in context: inout GraphicsContext, rect: CGRect, opacity: Double) {
        guard opacity > 0.001 else { return }
        var caret = context
        caret.opacity *= opacity
        caret.fill(Capsule().path(in: rect), with: .color(.primary))
    }
}
