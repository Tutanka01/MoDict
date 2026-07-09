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

    // MARK: Type

    static let hudLabelFont = Font.system(size: 12, weight: .medium)
    static let onboardingTitleFont = Font.system(size: 26, weight: .semibold)
    static let onboardingBodyFont = Font.system(size: 13)
}
