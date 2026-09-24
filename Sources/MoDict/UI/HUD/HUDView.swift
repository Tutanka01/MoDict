import SwiftUI

/// Where the card sits inside the oversized, transparent panel. The pinned
/// edges stay still while the card morphs and grows, so a card hanging below
/// the text cursor grows down and to the right, away from the words you are
/// writing, and a top-center card grows away from the menu bar and camera
/// housing.
struct HUDPlacement: Equatable {
    enum Pin: Equatable {
        case top
        case center
        case bottom
    }

    var pin: Pin = .center
    /// Pin the card's leading edge (anchored to the text cursor) instead of
    /// centering it horizontally.
    var leading = false

    var alignment: Alignment {
        switch (pin, leading) {
        case (.top, false): .top
        case (.center, false): .center
        case (.bottom, false): .bottom
        case (.top, true): .topLeading
        case (.center, true): .leading
        case (.bottom, true): .bottomLeading
        }
    }

    /// Scaling around the pinned edge keeps it visually still during
    /// appear/disappear: the card seems to come from, and return to, its anchor.
    var scaleAnchor: UnitPoint {
        switch (pin, leading) {
        case (.top, false): .top
        case (.center, false): .center
        case (.bottom, false): .bottom
        case (.top, true): .topLeading
        case (.center, true): .leading
        case (.bottom, true): .bottomLeading
        }
    }

    var insets: EdgeInsets {
        let margin = Theme.hudCardEdgeMargin
        return EdgeInsets(
            top: pin == .top ? margin : 0,
            leading: leading ? margin : 0,
            bottom: pin == .bottom ? margin : 0,
            trailing: 0
        )
    }
}

/// Microphone level as the bars display it, advanced once per display frame.
///
/// The microphone reports a level once per audio buffer, about 12 times a
/// second. Drawn as-is, the bars hold for several frames and then jump, which
/// reads as lag. This eases toward the latest reading on the display clock
/// (fast attack, slower release), so the bars glide at 60 or 120 Hz.
final class HUDLevelSmoother {
    /// Latest microphone reading, 0…1.
    var target: CGFloat = 0
    private(set) var value: CGFloat = 0
    private var lastTime: TimeInterval?

    static let attack: TimeInterval = 0.045
    static let release: TimeInterval = 0.16

    func value(at time: TimeInterval) -> CGFloat {
        // A long gap (first frame, a paused timeline) must not teleport the bars.
        let dt = lastTime.map { min(max(time - $0, 0), 0.05) } ?? 0
        lastTime = time
        let tau = target > value ? Self.attack : Self.release
        value += (target - value) * CGFloat(1 - exp(-dt / tau))
        return value
    }

    func reset() {
        target = 0
        value = 0
        lastTime = nil
    }
}

/// Observable state backing the composition card.
///
/// The level and the voice activity are deliberately not published: the
/// display-clock views read them directly, avoiding a full card re-render for
/// every microphone buffer.
@MainActor
final class HUDModel: ObservableObject {
    @Published var state: HUDState = .recording
    /// The preview text with its per-character entrance stamps.
    @Published private(set) var ink = HUDInk()
    /// The stop gesture, e.g. "Release to paste".
    @Published var actionHint = "Release to paste"
    /// Shown even after the gesture is learned (hybrid's switch to hands-free).
    @Published var actionHintIsPersistent = false
    /// The gesture and Esc hints, only while the gesture is still being learned.
    @Published var showsGuidance = true
    /// Sustained silence while recording: "Hearing nothing".
    @Published var silenceWarning = false
    /// The elapsed clock, revealed only once a dictation runs long.
    @Published var showsClock = false
    @Published var placement = HUDPlacement()
    @Published var contentScale: CGFloat = 0.92
    @Published var contentOpacity: Double = 0
    @Published var shakeToken: Int = 0
    /// Words inserted on success: the quiet answer to "did the long dictation survive?"
    @Published var insertedWordCount: Int?
    /// When this recording session began; nil outside `.recording`.
    @Published var sessionStartDate: Date?

    let level = HUDLevelSmoother()
    let voice = HUDVoiceActivity()

    /// Stamps new characters with the display clock's time base, the one the
    /// caption's `TimelineView` draws with.
    func setPartial(_ partial: PartialTranscript?, at date: Date = Date()) {
        ink.update(partial, at: date.timeIntervalSinceReferenceDate)
    }
}

struct HUDRootView: View {
    @ObservedObject var model: HUDModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HUDCompositionCard(model: model)
            .scaleEffect(reduceMotion ? 1 : model.contentScale, anchor: model.placement.scaleAnchor)
            .opacity(model.contentOpacity)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: model.placement.alignment)
            .padding(model.placement.insets)
            .allowsHitTesting(false)
    }
}

// MARK: - Composition card

/// One continuous surface of smoked glass that changes shape with what it has
/// to say:
///
/// - a capsule while you speak and no words exist yet: MoDict's mark come
///   alive, your voice waveform beside a text cursor (always the case with
///   batch-only models),
/// - a card, exactly once, when the first preview words arrive: the cursor
///   moves into the text and rides at the end of your words; the width is
///   then fixed for the session, so the caption never rewraps mid-sentence,
/// - a capsule again for "Pasted", which then retracts toward its anchor.
///
/// Guidance (the stop gesture, Esc) is shown only while the gesture is being
/// learned; the elapsed clock only once a dictation runs long. At rest, the
/// card is nothing but your voice and your words.
private struct HUDCompositionCard: View {
    @ObservedObject var model: HUDModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        surface
            // Two shadows, like a real object: a tight contact shadow that
            // seats the glass, and a soft ambient one that lifts it.
            .shadow(color: Theme.hudContactShadow, radius: 1.5, x: 0, y: 1)
            .shadow(color: Theme.hudShadow, radius: Theme.hudShadowRadius, x: 0, y: Theme.hudShadowY)
            .keyframeAnimator(initialValue: CGFloat(0), trigger: reduceMotion ? 0 : model.shakeToken) { view, x in
                view.offset(x: x)
            } keyframes: { _ in
                KeyframeTrack {
                    CubicKeyframe(-4, duration: 0.05)
                    CubicKeyframe(4, duration: 0.05)
                    CubicKeyframe(-4, duration: 0.05)
                    CubicKeyframe(4, duration: 0.05)
                    CubicKeyframe(0, duration: 0.05)
                }
            }
            .animation(reduceMotion ? nil : Theme.stateSpring, value: model.state)
            .animation(reduceMotion ? nil : Theme.textSpring, value: hasPreview)
    }

    /// Smoked glass. On macOS 26+ it is Liquid Glass — refraction, a lit
    /// edge, the faint color of what lies beneath — tinted deep enough that
    /// white text reads over a white page and a black terminal alike. macOS
    /// 15 builds the same smoke from AppKit's `hudWindow` material. The panel
    /// pins both to a constant dark identity (see HUDPanel).
    ///
    /// One rounded rectangle for every state: at capsule height its radius is
    /// exactly half the height, so capsule ↔ card is a single continuous morph.
    @ViewBuilder private var surface: some View {
        // One stable container carries the glass: switching content must
        // morph a single surface, never fade one glass out over another.
        // Clipped to the glass: while the capsule grows into the card, the
        // words (already laid out at the card's final width) never draw
        // outside the surface.
        let base = ZStack(alignment: .leading) { content }
            .frame(width: cardWidth, alignment: .leading)
            .fixedSize(horizontal: cardWidth == nil, vertical: true)
            .clipShape(cardShape)
        if #available(macOS 26.0, *) {
            base
                .glassEffect(.clear.tint(Theme.hudGlassTint), in: cardShape)
        } else {
            base
                .background(Theme.hudSmoke, in: cardShape)
                .background(HUDMaterial(cornerRadius: Theme.hudCornerRadius))
                .overlay(cardShape.strokeBorder(Theme.hudRim, lineWidth: 0.75))
        }
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.hudCornerRadius, style: .continuous)
    }

    /// Recording and transcribing are one branch, one view: releasing the
    /// key keeps the waveform, the caption and its measured height, and changes
    /// only their motion. Between branches the choreography runs in sequence:
    /// the old content leaves at once, the surface morphs, then the new
    /// content arrives, so two messages never overlap mid-morph.
    @ViewBuilder private var content: some View {
        switch model.state {
        case .recording, .transcribing:
            sessionContent(settling: model.state == .transcribing)
                .transition(exchange)
        case .success:
            successContent
                .transition(exchange)
        case let .error(message, symbol):
            errorContent(message: message, symbol: symbol)
                .transition(exchange)
        }
    }

    private var exchange: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.94, anchor: .leading))
                .animation(.easeOut(duration: 0.2).delay(0.1)),
            removal: .opacity.animation(.easeOut(duration: 0.08))
        )
    }

    /// Recording and transcribing share one layout: releasing the key changes
    /// motion, not structure. The waveform stops listening and ripples toward
    /// the cursor, the cursor breathes, and a light sweeps the words while the
    /// final text is prepared.
    private func sessionContent(settling: Bool) -> some View {
        VStack(alignment: .leading, spacing: hasPreview ? Theme.hudRowSpacing : 0) {
            HStack(spacing: 10) {
                HUDVoicePrint(voice: model.voice, level: model.level, settling: settling,
                              caretPresence: hasPreview ? 0 : 1)

                if hasTrailingItems(settling: settling) {
                    // Collapses to the row spacing in the capsule; pushes the
                    // hints to the trailing edge of the card.
                    Spacer(minLength: 0)
                    trailingItems(settling: settling)
                }
            }
            .frame(height: Theme.hudRowHeight)

            if hasPreview {
                HUDCaption(ink: model.ink, settling: settling, voice: model.voice)
                    // The words arrive as the surface finishes growing: the
                    // eye follows one motion at a time.
                    .transition(.opacity.animation(
                        reduceMotion ? nil : .easeOut(duration: 0.2).delay(0.12)))
            }
        }
        .padding(.leading, Theme.hudHorizontalPadding)
        .padding(.trailing, model.showsGuidance ? Theme.hudChipTrailingPadding : Theme.hudHorizontalPadding)
        .padding(.vertical, hasPreview ? Theme.hudVerticalPadding : Theme.hudCompactVerticalPadding)
    }

    private func hasTrailingItems(settling: Bool) -> Bool {
        if model.showsGuidance { return true }
        if settling { return false }
        return model.silenceWarning || model.actionHintIsPersistent || model.showsClock
    }

    @ViewBuilder private func trailingItems(settling: Bool) -> some View {
        // The hint is the one flexible element: everything else keeps its
        // natural width, so an overlong hint truncates with an ellipsis
        // instead of squeezing the row, and the height never changes.
        if let hint = hint(settling: settling) {
            hintText(hint, warning: !settling && model.silenceWarning)
                // One message at a time: the old one leaves at once, the new
                // one fades in, so two hints never overlap mid-change.
                .id(hint)
                .transition(reduceMotion ? .opacity : .asymmetric(
                    insertion: .opacity.animation(.easeOut(duration: 0.18).delay(0.06)),
                    removal: .opacity.animation(.easeOut(duration: 0.06))
                ))
        }
        if !settling && model.showsClock {
            elapsedClock
        }
        if model.showsGuidance {
            escapeChip
        }
    }

    private func hint(settling: Bool) -> String? {
        if settling { return model.showsGuidance ? "Transcribing" : nil }
        if model.silenceWarning { return "Hearing nothing — check your microphone" }
        if model.showsGuidance || model.actionHintIsPersistent { return model.actionHint }
        return nil
    }

    private func hintText(_ text: String, warning: Bool) -> some View {
        Text(text)
            .font(Theme.hudHintFont)
            .foregroundStyle(warning ? Color.orange : Color.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    /// Revealed only once a dictation runs long; the reserve keeps the width
    /// stable as the digits change.
    private var elapsedClock: some View {
        Text("0:00")
            .font(Theme.hudHintFont.monospacedDigit())
            .foregroundStyle(.clear)
            .accessibilityHidden(true)
            .fixedSize()
            .overlay(alignment: .trailing) {
                TimelineView(.animation(minimumInterval: 1.0 / 4, paused: reduceMotion)) { context in
                    Text(recordingElapsed(from: context.date))
                        .font(Theme.hudHintFont.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
            .transition(.opacity)
    }

    /// Seconds since the recording began; the clock resets with each session.
    private func recordingElapsed(from date: Date) -> String {
        let elapsed = max(0, Int(date.timeIntervalSince(model.sessionStartDate ?? date)))
        return String(format: "%d:%02d", elapsed / 60, elapsed % 60)
    }

    private var successContent: some View {
        HStack(spacing: 8) {
            HUDCheckmark()
            Text("Pasted")
                .font(Theme.hudTitleFont)
                .fixedSize()
            if let words = model.insertedWordCount, words > 0 {
                Text(words == 1 ? "1 word" : "\(words) words")
                    .font(Theme.hudHintFont.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
        .foregroundStyle(Color.primary)
        .frame(height: Theme.hudRowHeight)
        .padding(.leading, Theme.hudHorizontalPadding - 3)
        .padding(.trailing, Theme.hudHorizontalPadding + 1)
        .padding(.vertical, Theme.hudCompactVerticalPadding)
    }

    private func errorContent(message: String, symbol: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.red)
            Text(message)
                .font(Theme.hudTitleFont)
                .foregroundStyle(Color.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Theme.hudHorizontalPadding)
        .padding(.vertical, 12)
    }

    /// The one swallowed key, shown for the whole cancellable window while
    /// the gesture is being learned.
    private var escapeChip: some View {
        Text("esc")
            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.primary.opacity(0.16), lineWidth: 0.5))
            .accessibilityLabel("Escape to cancel")
    }

    private var hasPreview: Bool {
        guard model.state == .recording || model.state == .transcribing else { return false }
        return !model.ink.isEmpty
    }

    /// nil = the natural width of the content (the capsules).
    private var cardWidth: CGFloat? {
        switch model.state {
        case .recording, .transcribing:
            // Once words exist, one width for the rest of the session: a width
            // change would rewrap the caption, which reads as jitter.
            return hasPreview ? Theme.hudSessionWidth : nil
        case .success:
            return nil
        case .error:
            return Theme.hudErrorWidth
        }
    }
}

/// "Pasted": a check drawn in one stroke and knocked out of a solid disc, so
/// the glass shows through it, the way the mark is knocked out of the app
/// icon's tile. A trimmed path, so it draws identically on every macOS.
private struct HUDCheckmark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white)
                .scaleEffect(drawn || reduceMotion ? 1 : 0.5)
            Self.check
                .trim(from: 0, to: drawn || reduceMotion ? 1 : 0)
                .stroke(Color.black, style: StrokeStyle(lineWidth: 2.1, lineCap: .round, lineJoin: .round))
                .blendMode(.destinationOut)
        }
        .frame(width: 17, height: 17)
        .compositingGroup()
        .accessibilityHidden(true)
        .onAppear {
            withAnimation(Theme.checkSpring.delay(0.06)) { drawn = true }
        }
    }

    private static let check = Path { path in
        path.move(to: CGPoint(x: 5.1, y: 8.9))
        path.addLine(to: CGPoint(x: 7.6, y: 11.4))
        path.addLine(to: CGPoint(x: 12.1, y: 6.0))
    }
}
