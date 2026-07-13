import SwiftUI

/// Design tokens for MoDict. Single source of truth — see Docs/DESIGN.md.
/// Monochrome: materials, `Color.primary`/`.secondary`, and system red for the
/// recording dot and errors only.
enum Theme {

    // MARK: HUD geometry

    static let hudBottomOffset: CGFloat = 28
    /// Native gap between the menu bar and the card's top edge in top-center
    /// mode (Apple's notification banners sit ~10 pt below the menu bar).
    static let hudTopGap: CGFloat = 10
    /// Inset between the card's pinned edge and the panel edge — sized so the
    /// drop shadow (radius 24, y 10) never clips against the panel bounds.
    static let hudCardEdgeMargin: CGFloat = 36
    /// One width for the whole recording → transcribing session: changing it
    /// mid-dictation would rewrap the caption, which reads as jitter.
    static let hudSessionWidth: CGFloat = 380
    static let hudSuccessWidth: CGFloat = 118
    static let hudErrorWidth: CGFloat = 280
    static let hudCornerRadius: CGFloat = 16
    static let hudHorizontalPadding: CGFloat = 15
    static let hudVerticalPadding: CGFloat = 13
    /// Three lines at the preview font's natural line height + line spacing.
    static let hudPreviewHeight: CGFloat = 58
    /// Distance from the pointer to the center of a near-pointer card.
    static let hudPointerCenterOffset: CGFloat = 78

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
    /// One-time compact → preview height growth: fully damped so the caption
    /// baseline never overshoots. Per-partial text updates are NOT animated —
    /// interpolating a live caption is what makes it swim.
    static let textSpring = Animation.spring(response: 0.4, dampingFraction: 0.9)
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

    static let hudTitleFont = Font.system(size: 12.5, weight: .semibold)
    static let hudHintFont = Font.system(size: 10.5, weight: .medium)
    static let hudPreviewFont = Font.system(size: 13, weight: .regular)
    static let onboardingTitleFont = Font.system(size: 26, weight: .semibold)
    static let onboardingBodyFont = Font.system(size: 13)
}
