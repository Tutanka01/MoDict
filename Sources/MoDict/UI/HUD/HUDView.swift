import SwiftUI

/// Observable state backing the HUD capsule. Owned by `HUDController`, observed by
/// `HUDRootView`.
///
/// `level` is deliberately *not* `@Published`: it is written at microphone-buffer
/// rate and read only by the waveform through a `TimelineView`, which redraws on
/// its own clock. Publishing it would invalidate the whole HUD on every buffer.
@MainActor
final class HUDModel: ObservableObject {
    @Published var state: HUDState = .recording
    /// Whole-capsule appearance, animated by the controller (spring in, ease-out).
    @Published var contentScale: CGFloat = 0.92
    @Published var contentOpacity: Double = 0
    /// Bumped on every error presentation to (re)trigger the shake.
    @Published var shakeToken: Int = 0

    var level: CGFloat = 0
}

/// Root of the SwiftUI content hosted in the panel. Fills the (larger than the
/// capsule) hosting view so the capsule sits centered with room for its shadow,
/// and applies the appear/disappear scale + opacity.
struct HUDRootView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        HUDCapsule(model: model)
            .scaleEffect(model.contentScale)
            .opacity(model.contentOpacity)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
    }
}

// MARK: - Capsule

private struct HUDCapsule: View {
    @ObservedObject var model: HUDModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        content
            .frame(height: Theme.hudHeight)
            .frame(width: fixedWidth)
            .frame(maxWidth: Theme.hudErrorMaxWidth)
            // fixedSize makes the frame stack resolve against the content's ideal
            // width instead of the (340 pt) hosting proposal — without it the
            // maxWidth frame stretches the capsule to 260 pt in every state.
            .fixedSize(horizontal: true, vertical: false)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule().strokeBorder(Theme.hairline(for: scheme), lineWidth: 0.5)
            )
            .shadow(
                color: Theme.hudShadow,
                radius: Theme.hudShadowRadius,
                x: 0,
                y: Theme.hudShadowY
            )
            .keyframeAnimator(initialValue: CGFloat(0), trigger: model.shakeToken) { view, x in
                view.offset(x: x)
            } keyframes: { _ in
                // ±4 pt, twice, 0.05 s per leg (see DESIGN.md → error state).
                KeyframeTrack {
                    CubicKeyframe(-4, duration: 0.05)
                    CubicKeyframe(4, duration: 0.05)
                    CubicKeyframe(-4, duration: 0.05)
                    CubicKeyframe(4, duration: 0.05)
                    CubicKeyframe(0, duration: 0.05)
                }
            }
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .recording:
            HUDRecordingContent(model: model)
                .transition(.opacity)
        case .transcribing:
            HUDTranscribingDots()
                .transition(.opacity)
        case .success:
            HUDSuccessMark()
                .transition(.scale(scale: 0.6).combined(with: .opacity))
        case let .error(message, symbol):
            HUDErrorContent(message: message, symbol: symbol)
                .transition(.opacity)
        }
    }

    /// Fixed target widths for the settled states; `nil` lets the error state size
    /// to its text (clamped by the outer `maxWidth`). Width changes are animated by
    /// the controller wrapping state mutations in `Theme.stateSpring`.
    private var fixedWidth: CGFloat? {
        switch model.state {
        case .recording: return Theme.hudRecordingWidth
        case .transcribing: return Theme.hudTranscribingWidth
        case .success: return Theme.hudSuccessWidth
        case .error: return nil
        }
    }
}

// MARK: - Recording (dot + waveform)

private struct HUDRecordingContent: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        // One clock drives both the dot pulse and the waveform so they stay in
        // sync and the view redraws independently of `model.level` writes.
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 8) {
                HUDRecordingDot(t: t)
                HUDWaveform(level: model.level, t: t)
            }
        }
    }
}

private struct HUDRecordingDot: View {
    let t: TimeInterval

    var body: some View {
        let phase = 0.5 + 0.5 * sin(t * 3.2)   // 0…1, ~0.5 Hz
        Circle()
            .fill(Theme.recordingDot)
            .frame(width: 6, height: 6)
            .opacity(0.65 + 0.35 * phase)
            .scaleEffect(0.9 + 0.12 * phase)
    }
}

private struct HUDWaveform: View {
    let level: CGFloat
    let t: TimeInterval

    // Center bars taller; per-bar phase + speed so the cluster never moves in
    // lockstep and reads as organic.
    private static let shape: [CGFloat] = [0.50, 0.72, 0.90, 1.00, 0.90, 0.72, 0.50]
    private static let phase: [Double]  = [0.0, 0.8, 1.7, 2.5, 3.4, 4.2, 5.1]
    private static let speed: [Double]  = [8.2, 9.1, 7.6, 8.8, 7.9, 9.4, 8.0]

    var body: some View {
        HStack(spacing: Theme.waveformBarGap) {
            ForEach(0..<Theme.waveformBarCount, id: \.self) { i in
                Capsule()
                    .fill(Color.primary)
                    .frame(width: Theme.waveformBarWidth, height: barHeight(i))
            }
        }
        .frame(height: Theme.waveformBarMaxHeight)
    }

    private func barHeight(_ i: Int) -> CGFloat {
        let minH = Theme.waveformBarMinHeight
        let maxH = Theme.waveformBarMaxHeight
        let shape = Self.shape[i]

        // Near silence: rest at the floor with a barely visible slow breathing.
        if level < 0.03 {
            let breath = 0.5 + 0.5 * sin(t * 1.05 + Self.phase[i])
            return minH + 1.1 * CGFloat(breath) * shape
        }

        let wobble = 0.55 + 0.45 * (0.5 + 0.5 * sin(t * Self.speed[i] + Self.phase[i]))
        let amp = min(1, level * shape * CGFloat(wobble))
        return minH + (maxH - minH) * amp
    }
}

// MARK: - Transcribing (three sequential dots)

private struct HUDTranscribingDots: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { i in
                    let v = 0.5 + 0.5 * sin(t * 4.4 - Double(i) * 0.7)
                    Circle()
                        .fill(Color.primary)
                        .frame(width: 6, height: 6)
                        .opacity(0.35 + 0.55 * v)
                        .scaleEffect(0.75 + 0.25 * v)
                }
            }
        }
    }
}

// MARK: - Success

private struct HUDSuccessMark: View {
    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Color.primary)
    }
}

// MARK: - Error

private struct HUDErrorContent: View {
    let message: String
    let symbol: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.red)
            Text(message)
                .font(Theme.hudLabelFont)
                .foregroundStyle(Color.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .fixedSize()
    }
}
