import AppKit
import SwiftUI

/// Design tokens for MoDict. Single source of truth — see Docs/DESIGN.md.
/// Monochrome: materials, `Color.primary`/`.secondary`, system red for errors
/// (and the menu's recording dot), system orange for the silence warning only.
enum Theme {

    // MARK: HUD geometry

    static let hudBottomOffset: CGFloat = 28
    /// Native gap between the menu bar and the card's top edge in top-center
    /// mode (Apple's notification banners sit ~10 pt below the menu bar).
    static let hudTopGap: CGFloat = 10
    /// Inset between the card's pinned edge and the panel edge — sized so the
    /// drop shadow (radius 24, y 10) never clips against the panel bounds.
    static let hudCardEdgeMargin: CGFloat = 36
    /// Card width once preview words exist, fixed for the rest of the
    /// session: changing it mid-dictation would rewrap the caption.
    static let hudSessionWidth: CGFloat = 380
    static let hudErrorWidth: CGFloat = 280
    /// Half the capsule height, so the capsule and the card are one shape.
    static let hudCornerRadius: CGFloat = 20
    /// One leading inset for the capsule and the card, so the waveform
    /// never shifts during the morph and the words start exactly at the text
    /// cursor.
    static let hudHorizontalPadding: CGFloat = 15
    /// Trailing inset when the esc chip ends the row: its corners then sit
    /// concentric with the capsule's.
    static let hudChipTrailingPadding: CGFloat = 11
    static let hudVerticalPadding: CGFloat = 12
    /// Between the voice row and the words.
    static let hudRowSpacing: CGFloat = 8
    /// Capsule states (voice bars, Pasted): 22 pt bars + 2 × 9 = 40 pt tall.
    static let hudCompactVerticalPadding: CGFloat = 9
    /// Gap between the text cursor's line and the card hanging below (or above) it.
    static let hudCaretGap: CGFloat = 8
    /// A dictation must run this long before the elapsed clock appears.
    static let hudClockDelay: TimeInterval = 10
    static let hudPreviewLineSpacing: CGFloat = 3
    /// The preview font's natural line height (ascender + descender + leading).
    static let hudPreviewLineHeight: CGFloat = {
        let font = NSFont.systemFont(ofSize: hudPreviewFontSize)
        return ceil(font.ascender - font.descender + font.leading)
    }()
    /// The caption grows one line at a time up to three lines, then glides.
    static let hudPreviewHeight: CGFloat = hudPreviewLineHeight * 3 + hudPreviewLineSpacing * 2
    /// Distance from the pointer to the center of a near-pointer card (the
    /// fallback when the focused app reports no text cursor).
    static let hudPointerCenterOffset: CGFloat = 78

    // MARK: Waveform and cursor (the living mark)

    static let waveformBarCount = 7
    static let waveformBarWidth: CGFloat = 3
    static let waveformBarGap: CGFloat = 3
    static let waveformBarMinHeight: CGFloat = 4
    static let waveformBarMaxHeight: CGFloat = 22
    /// Height of the voice row (and of the capsule's content).
    static let hudRowHeight: CGFloat = 22
    static let caretWidth: CGFloat = 2
    static let caretHeight: CGFloat = 22
    /// Between the waveform and the cursor beside it.
    static let caretGap: CGFloat = 6
    /// A native caret's rhythm: about half a second on, half a second off.
    static let caretBlinkPeriod: TimeInterval = 1.06
    /// EMA smoothing factors for the mic level.
    static let levelAttack: Float = 0.55
    static let levelRelease: Float = 0.18

    // MARK: Motion

    static let appearSpring = Animation.spring(response: 0.32, dampingFraction: 0.75)
    static let stateSpring = Animation.spring(response: 0.32, dampingFraction: 0.75)
    /// One-time compact → preview height growth: fully damped so the caption
    /// baseline never overshoots. Per-partial text layout is NOT animated —
    /// interpolating a live caption is what makes it swim; new words animate
    /// in the renderer instead (drawing only).
    static let textSpring = Animation.spring(response: 0.4, dampingFraction: 0.9)
    /// Line growth and the glide as a new line wraps: critically damped, so a
    /// partial arriving mid-glide just retargets it.
    static let captionSpring = Animation.spring(response: 0.36, dampingFraction: 1)
    /// The success check drawing itself.
    static let checkSpring = Animation.spring(response: 0.42, dampingFraction: 0.82)
    static let disappearDuration: TimeInterval = 0.18
    /// How long transient HUD states stay on screen before auto-hiding.
    static let successDwell: TimeInterval = 0.7
    static let errorDwell: TimeInterval = 2.2

    // MARK: Color & materials

    /// The menu's recording indicator. The HUD needs none: its bars move with your voice.
    static let recordingDot = Color.red.opacity(0.9)
    /// Smoked glass (macOS 26+): the `.clear` Liquid Glass variant tinted deep
    /// enough that white text reads over any content. `.regular` stays a flat
    /// mid gray over light pages whatever its tint.
    static let hudGlassTint = Color.black.opacity(0.7)
    /// The same smoke over AppKit's `hudWindow` material (macOS 15).
    static let hudSmoke = Color.black.opacity(0.5)
    /// Lit top edge of the macOS 15 surface; Liquid Glass carries its own.
    static let hudRim = LinearGradient(colors: [.white.opacity(0.26), .white.opacity(0.07)],
                                       startPoint: .top, endPoint: .bottom)
    static let hudContactShadow = Color.black.opacity(0.2)
    static let hudShadow = Color.black.opacity(0.26)
    static let hudShadowRadius: CGFloat = 22
    static let hudShadowY: CGFloat = 12

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
    static let hudPreviewFontSize: CGFloat = 14
    static let hudPreviewFont = Font.system(size: hudPreviewFontSize, weight: .regular)
    static let onboardingTitleFont = Font.system(size: 26, weight: .semibold)
    static let onboardingBodyFont = Font.system(size: 13)
}

/// The same gesture guide across setup, settings, and the menu.
enum DictationGesture {
    static func instruction(key: DictationKey, mode: HotkeyMonitor.Mode) -> String {
        switch mode {
        case .pushToTalk: "Hold \(key.inlineName), speak, then release to paste."
        case .toggle: "Tap \(key.inlineName) to start. Tap again to paste."
        case .hybrid: "Hold \(key.inlineName) to talk, or tap for hands-free."
        }
    }
}

struct ShortcutGuide: View {
    let key: DictationKey
    let mode: HotkeyMonitor.Mode

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: key.keycapSymbol)
                .font(.system(size: 23, weight: .medium))
                .frame(width: 54, height: 50)
                .background(.background, in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(.primary.opacity(0.12)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(DictationGesture.instruction(key: key, mode: mode))
                    .font(.system(size: 13, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                Text("Esc to cancel · Paste into any app")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
    }
}
