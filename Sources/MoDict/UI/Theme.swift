import SwiftUI

/// Design tokens for MoDict. Single source of truth — see Docs/DESIGN.md.
/// Monochrome: materials, `Color.primary`/`.secondary`, and system red for the
/// recording dot and errors only.
enum Theme {

    // MARK: HUD geometry

    static let hudHeight: CGFloat = 38
    static let hudBottomOffset: CGFloat = 28
    static let hudRecordingWidth: CGFloat = 148
    static let hudTranscribingWidth: CGFloat = 96
    static let hudSuccessWidth: CGFloat = 56
    static let hudErrorMaxWidth: CGFloat = 260
    /// Capsule cap while a live partial transcript is shown.
    static let hudPartialMaxWidth: CGFloat = 420
    /// Cap for the transcript text itself (capsule width minus dot/waveform/padding).
    static let hudPartialTextMaxWidth: CGFloat = 320
    /// Horizontal content inset of the recording/transcribing capsule.
    static let hudContentPadding: CGFloat = 14
    /// Width of the soft leading fade (clear → opaque) that replaces the hard
    /// head-truncation ellipsis once the live transcript overflows its column.
    static let hudTextFadeWidth: CGFloat = 24

    // MARK: Waveform

    static let waveformBarCount = 7
    static let waveformBarWidth: CGFloat = 3
    static let waveformBarGap: CGFloat = 3
    static let waveformBarMinHeight: CGFloat = 4
    static let waveformBarMaxHeight: CGFloat = 22
    /// EMA smoothing factors for the mic level.
    static let levelAttack: Float = 0.55
    static let levelRelease: Float = 0.18

    // MARK: Motion

    static let appearSpring = Animation.spring(response: 0.32, dampingFraction: 0.75)
    static let stateSpring = Animation.spring(response: 0.32, dampingFraction: 0.75)
    static let barSpring = Animation.interpolatingSpring(stiffness: 170, damping: 15)
    /// Live-transcript updates: slightly softer and fully damped so the
    /// trailing-aligned text never overshoots and jitters as the capsule grows.
    static let textSpring = Animation.spring(response: 0.4, dampingFraction: 0.9)
    /// Engage/disengage of the transcript's leading fade mask.
    static let textFadeEase = Animation.easeOut(duration: 0.2)
    static let disappearDuration: TimeInterval = 0.18
    /// How long transient HUD states stay on screen before auto-hiding.
    static let successDwell: TimeInterval = 0.7
    static let errorDwell: TimeInterval = 2.2

    // MARK: Color & materials

    static let recordingDot = Color.red.opacity(0.9)
    static let hudShadow = Color.black.opacity(0.18)
    static let hudShadowRadius: CGFloat = 24
    static let hudShadowY: CGFloat = 10

    static func hairline(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)
    }

    // MARK: Keycap picker (Settings → General)

    static let keycapWidth: CGFloat = 46
    static let keycapHeight: CGFloat = 38
    static let keycapCornerRadius: CGFloat = 9
    /// Tap-down feedback: the cap compresses like a physical key.
    static let keycapPressedScale: CGFloat = 0.96
    static let keycapPressSpring = Animation.spring(response: 0.25, dampingFraction: 0.7)
    /// Soft lift shown only under the selected cap.
    static let keycapSelectedShadow = Color.black.opacity(0.10)
    static let keycapSelectedShadowRadius: CGFloat = 3
    static let keycapSelectedShadowY: CGFloat = 1

    // MARK: Type

    /// Point size behind `hudLabelFont` — also used to measure the live
    /// transcript for the overflow fade.
    static let hudLabelFontSize: CGFloat = 12
    static let hudLabelFont = Font.system(size: hudLabelFontSize, weight: .medium)
    static let onboardingTitleFont = Font.system(size: 26, weight: .semibold)
    static let onboardingBodyFont = Font.system(size: 13)
}
