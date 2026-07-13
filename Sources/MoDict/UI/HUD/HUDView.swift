import SwiftUI

/// Which panel edge the card is pinned to. The panel is an oversized
/// transparent canvas; pinning the card to the edge nearest the screen edge
/// makes growth move only the free edge — a top-center card grows downward,
/// away from the menu bar and the camera housing.
enum HUDPlacement {
    case top
    case center
    case bottom
}

/// Observable state backing the near-pointer composition preview.
///
/// `level` is deliberately not published: the display-clock waveform reads it
/// directly, avoiding a full card re-render for every microphone buffer.
@MainActor
final class HUDModel: ObservableObject {
    @Published var state: HUDState = .recording
    @Published var partial: PartialTranscript?
    @Published var actionHint = "Release to paste"
    @Published var placement: HUDPlacement = .center
    @Published var contentScale: CGFloat = 0.94
    @Published var contentOpacity: Double = 0
    @Published var shakeToken: Int = 0

    var level: CGFloat = 0
}

struct HUDRootView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        HUDCompositionCard(model: model)
            .scaleEffect(model.contentScale, anchor: scaleAnchor)
            .opacity(model.contentOpacity)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .padding(edgeInsets)
            .allowsHitTesting(false)
    }

    private var alignment: Alignment {
        switch model.placement {
        case .top: return .top
        case .center: return .center
        case .bottom: return .bottom
        }
    }

    /// Scaling around the pinned edge keeps that edge visually still during
    /// appear/disappear, so the card seems attached to its screen edge.
    private var scaleAnchor: UnitPoint {
        switch model.placement {
        case .top: return .top
        case .center: return .center
        case .bottom: return .bottom
        }
    }

    private var edgeInsets: EdgeInsets {
        switch model.placement {
        case .top:
            return EdgeInsets(top: Theme.hudCardEdgeMargin, leading: 0, bottom: 0, trailing: 0)
        case .center:
            return EdgeInsets()
        case .bottom:
            return EdgeInsets(top: 0, leading: 0, bottom: Theme.hudCardEdgeMargin, trailing: 0)
        }
    }
}

// MARK: - Composition card

/// A compact composition surface rather than a status capsule: it tells the user
/// what MoDict is doing, previews only a few recent lines, and makes the commit
/// gesture explicit. The focused application remains untouched until stop.
private struct HUDCompositionCard: View {
    @ObservedObject var model: HUDModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        content
            .frame(width: cardWidth, alignment: .leading)
            .background(.regularMaterial, in: cardShape)
            .overlay(cardShape.strokeBorder(Theme.hairline(for: scheme), lineWidth: 0.75))
            .shadow(
                color: Theme.hudShadow,
                radius: Theme.hudShadowRadius,
                x: 0,
                y: Theme.hudShadowY
            )
            .keyframeAnimator(initialValue: CGFloat(0), trigger: model.shakeToken) { view, x in
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
            .animation(Theme.stateSpring, value: model.state)
            .animation(Theme.textSpring, value: hasPreview)
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.hudCornerRadius, style: .continuous)
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .recording:
            recordingContent
                .transition(.opacity)
        case .transcribing:
            transcribingContent
                .transition(.opacity)
        case .success:
            successContent
                .transition(.scale(scale: 0.92).combined(with: .opacity))
        case let .error(message, symbol):
            errorContent(message: message, symbol: symbol)
                .transition(.opacity)
        }
    }

    private var recordingContent: some View {
        VStack(alignment: .leading, spacing: hasPreview ? 11 : 0) {
            HStack(spacing: 9) {
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    HStack(spacing: 8) {
                        HUDRecordingDot(t: t)
                        HUDWaveform(level: model.level, t: t)
                    }
                }

                Text("Listening")
                    .font(Theme.hudTitleFont)

                Spacer(minLength: 12)

                Text(model.actionHint)
                    .font(Theme.hudHintFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let partial = model.partial, !partial.isEmpty {
                Divider().opacity(0.4)
                HUDPreviewText(partial: partial)
            }
        }
        .padding(.horizontal, Theme.hudHorizontalPadding)
        .padding(.vertical, Theme.hudVerticalPadding)
    }

    private var transcribingContent: some View {
        VStack(alignment: .leading, spacing: hasPreview ? 11 : 0) {
            HStack(spacing: 10) {
                HUDTranscribingDots()
                Text("Preparing paste")
                    .font(Theme.hudTitleFont)
                Spacer(minLength: 12)
                Text("Released")
                    .font(Theme.hudHintFont)
                    .foregroundStyle(.secondary)
            }

            if let partial = model.partial, !partial.isEmpty {
                Divider().opacity(0.4)
                HUDPreviewText(partial: partial)
            }
        }
        .padding(.horizontal, Theme.hudHorizontalPadding)
        .padding(.vertical, Theme.hudVerticalPadding)
    }

    private var successContent: some View {
        HStack(spacing: 9) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
            Text("Pasted")
                .font(Theme.hudTitleFont)
        }
        .foregroundStyle(Color.primary)
        .padding(.horizontal, Theme.hudHorizontalPadding)
        .padding(.vertical, 12)
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

    private var hasPreview: Bool {
        model.partial.map { !$0.isEmpty } ?? false
    }

    private var cardWidth: CGFloat {
        switch model.state {
        case .recording, .transcribing:
            // One width for the whole session: a mid-dictation width change
            // rewraps the caption on the same frame a partial lands, which
            // reads as jitter.
            return Theme.hudSessionWidth
        case .success:
            return Theme.hudSuccessWidth
        case .error:
            return Theme.hudErrorWidth
        }
    }
}

// MARK: - Private preview

/// A fixed-height, bottom-pinned caption window: the text lays out at its full
/// natural height, the viewport shows only the last three lines, and older
/// lines leave through a constant top fade.
///
/// Deliberately not a ScrollView. A programmatic scroll interpolates position
/// over time, so partials arriving mid-animation stutter; bottom-pinning has no
/// position to steer — every update is one deterministic layout pass, exactly
/// like a hardware caption display.
private struct HUDPreviewText: View {
    let partial: PartialTranscript

    var body: some View {
        Text(display)
            .font(Theme.hudPreviewFont)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Theme.hudPreviewHeight, alignment: .bottom)
            .clipped()
            .mask { topFade }
            .accessibilityLabel("Dictation preview")
    }

    /// One attributed string in one Text node — no per-update view insertion.
    /// Volatile words are de-emphasized: the monochrome translation of Apple's
    /// provisional-dictation underline.
    private var display: AttributedString {
        var confirmed = AttributedString(Self.tail(partial.confirmedText))
        confirmed.foregroundColor = Color.primary.opacity(0.92)
        guard !partial.volatileText.isEmpty else { return confirmed }

        let separator = partial.confirmedText.isEmpty ? "" : " "
        var volatile = AttributedString(separator + partial.volatileText)
        volatile.foregroundColor = Color.secondary
        return confirmed + volatile
    }

    /// Only the recent tail is rendered — the three-line window can never show
    /// more — so layout cost stays flat over a long dictation. Cuts on a word
    /// boundary so no half word ever surfaces under the fade.
    private static func tail(_ text: String, limit: Int = 220) -> String {
        guard text.count > limit else { return text }
        let suffix = text.suffix(limit)
        guard let space = suffix.firstIndex(where: \.isWhitespace) else {
            return String(suffix)
        }
        return String(suffix[suffix.index(after: space)...])
    }

    /// Always on, whether or not the text overflows: a conditional mask
    /// snaps in the first time a line crosses the threshold.
    private var topFade: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black.opacity(0.55), location: 0.14),
                .init(color: .black, location: 0.42),
                .init(color: .black, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

private struct HUDRecordingDot: View {
    let t: TimeInterval

    var body: some View {
        let phase = 0.5 + 0.5 * sin(t * 3.2)
        Circle()
            .fill(Theme.recordingDot)
            .frame(width: 7, height: 7)
            .opacity(0.68 + 0.32 * phase)
            .scaleEffect(0.9 + 0.12 * phase)
    }
}

private struct HUDWaveform: View {
    let level: CGFloat
    let t: TimeInterval

    private static let shape: [CGFloat] = [0.50, 0.72, 0.90, 1.00, 0.90, 0.72, 0.50]
    private static let phase: [Double] = [0.0, 0.8, 1.7, 2.5, 3.4, 4.2, 5.1]
    private static let speed: [Double] = [8.2, 9.1, 7.6, 8.8, 7.9, 9.4, 8.0]

    var body: some View {
        HStack(spacing: Theme.waveformBarGap) {
            ForEach(0..<Theme.waveformBarCount, id: \.self) { index in
                Capsule()
                    .fill(Color.primary.opacity(0.88))
                    .frame(width: Theme.waveformBarWidth, height: barHeight(index))
            }
        }
        .frame(height: Theme.waveformBarMaxHeight)
    }

    private func barHeight(_ index: Int) -> CGFloat {
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
}

private struct HUDTranscribingDots: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    let value = 0.5 + 0.5 * sin(t * 4.4 - Double(index) * 0.7)
                    Circle()
                        .fill(Color.primary)
                        .frame(width: 5, height: 5)
                        .opacity(0.30 + 0.60 * value)
                        .scaleEffect(0.75 + 0.25 * value)
                }
            }
            .frame(width: 28, height: Theme.waveformBarMaxHeight)
        }
    }
}
