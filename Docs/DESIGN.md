# MoDict — Design System

MoDict is a **quiet tool**. It should feel like a native part of macOS that Apple forgot to ship:
monochrome, weightless, instant. No dashboards, no gradients, no mascots. The entire visible
surface of the app is: a menu bar glyph, a floating capsule while you speak, a small onboarding
window, and a settings window. Every one of them must feel inevitable.

## Principles

1. **Invisible until needed.** Zero chrome at rest. The HUD appears on key-down and is gone the
   instant the text lands. Nothing lingers.
2. **Monochrome.** The palette is black, white, and materials. The only permitted accent is the
   system red, used exclusively and sparingly for error states and the tiny recording dot.
3. **Physics, not tweens.** All motion uses springs. Nothing fades linearly; things scale and
   settle like objects with mass.
4. **Text is the product.** MoDict's output is the user's words in someone else's app. Our UI
   never competes with that.

## Color & Materials

| Token | Value | Usage |
|---|---|---|
| Surface | `.ultraThinMaterial` | HUD capsule, menu bar popover |
| Stroke | `Color.white.opacity(0.08)` (dark) / `Color.black.opacity(0.06)` (light) | 0.5 pt hairline border on HUD |
| Primary | `Color.primary` | Waveform bars, icons, text |
| Secondary | `Color.secondary` | Captions, hints, timestamps |
| Recording dot | `Color.red.opacity(0.9)` | 6 pt circle, subtle pulse, recording state only |
| Error | `Color.red` | Error icon + label only. Never backgrounds. |
| Shadow | `Color.black.opacity(0.18)`, radius 24, y 10 | HUD only |

Dark and light mode both supported via semantic colors — never hardcode grays.

## Typography

System font only (SF Pro). Sizes:
- Onboarding titles: `.system(size: 26, weight: .semibold)`, tracking −0.5
- Onboarding body: `.system(size: 13)`, `.secondary`
- HUD label (error/hint text): `.system(size: 12, weight: .medium)`
- Menu bar list items: `.system(size: 13)`
- Settings: standard SwiftUI `Form` styles.

## The HUD (recording capsule)

The single most important surface. A floating capsule hosted in a non-activating `NSPanel`.

**Geometry**
- Height: **38 pt**. Corner radius: full capsule.
- Width is state-dependent and animates: recording ≈ **148 pt**, transcribing ≈ **96 pt**,
  success ≈ **56 pt**, error: fits text up to 260 pt.
- Position: bottom-center of the screen containing the mouse pointer, **28 pt** above the
  bottom edge. (Settings offers top-center as alternative.)
- Background `.ultraThinMaterial` in `Capsule()`, hairline stroke, soft shadow (see tokens).

**States & content**
| State | Content | Notes |
|---|---|---|
| `recording` | 6 pt red pulsing dot + 7 waveform bars | bars are `Color.primary` |
| `transcribing` | 3 dots pulsing in sequence | bars morph down into dots |
| `success` | `checkmark` SF Symbol, medium weight | shown ~700 ms then panel hides |
| `error(message)` | `exclamationmark.triangle` (or `mic.slash` / `lock.fill` when relevant) + 12 pt label | red icon, primary text; shown ~2.2 s |

**Waveform**
- 7 vertical bars: width 3 pt, gap 3 pt, corner radius 1.5 pt.
- Height 4–22 pt driven by the mic level (0…1), each bar with a slightly different multiplier
  and phase so the cluster feels organic; EMA smoothing (attack α≈0.55, release α≈0.18).
- Idle-silence: bars rest at 4 pt with a barely visible slow breathing.
- Bar height changes animate with `.interpolatingSpring(stiffness: 170, damping: 15)`.

**Panel motion**
- Appear: scale 0.92→1.00 + opacity 0→1, `.spring(response: 0.32, dampingFraction: 0.75)`.
  The panel must be visible **on key-down, before any audio arrives** (perceived latency).
- Disappear: opacity + scale to 0.96 over 0.18 s ease-out.
- Width changes between states animate with the same spring.
- Error state does a ±4 pt horizontal shake, twice, 0.05 s each.

## Menu bar

- Icon: SF Symbol `waveform` (template, monochrome). While recording, switch to
  `waveform` with `.symbolEffect(.variableColor.iterative)`; while the model downloads, show
  `arrow.down.circle` with the same treatment.
- `MenuBarExtra` with `.menuBarExtraStyle(.window)` — a small popover, not a system menu:
  - Status row: "Ready · hold right ⌘ to dictate" / "Downloading model… 42%" / "Recording…"
  - Last 5 transcriptions (two-line truncated). Click → copies to clipboard, brief check.
    Empty state: `waveform` glyph + "Your dictations will appear here".
  - Footer row: gear icon (Settings), power toggle (Enable/Disable), quit.
- Popover width: 300 pt. Everything `.ultraThinMaterial`-friendly, no explicit backgrounds.

## Onboarding (first launch)

A single fixed window, 520 × 600, centered, non-resizable, hidden title bar
(`.titlebarAppearsTransparent`, no title). Five steps, progress dots at the bottom,
primary button full-width at bottom (`.borderedProminent`, `.controlSize(.large)` — tint
`.primary` monochrome look via `.tint(.primary)`).

1. **Welcome** — App icon glyph, "Dictate anywhere." headline, one line: "Hold the right ⌘ key,
   speak, release. Your words appear wherever your cursor is. 100% on-device."
   A small animated rendition of the right-⌘ keycap pressing.
2. **Microphone** — why + button "Allow microphone" → `AVCaptureDevice.requestAccess`.
   Card flips to granted state with checkmark automatically.
3. **Accessibility & Input Monitoring** — two permission cards, each with status and an
   "Open Settings" action; auto-advance polling. Copy: "To detect the right ⌘ key and type
   text into your apps. MoDict never logs your keystrokes."
4. **Speech model** — "Parakeet v3 · 25 languages · runs on the Neural Engine · ~480 MB".
   One button "Download model" → thin progress bar (fraction + phase label: Downloading /
   Compiling). Resumable; errors inline with Retry.
5. **Try it** — a real `TextEditor` in the window: "Click below, hold right ⌘ and say
   something." On first successful insertion: checkmark spring animation + "That's it.
   MoDict lives in your menu bar." Button "Start dictating" closes onboarding.

Each step: SF Symbol in a 56 pt circle (`.ultraThinMaterial` fill), title, one short paragraph,
action. Nothing else. Steps advance automatically when their condition is met.

## Settings

Standard `Settings` scene, `TabView` style like System Settings. Small — flat hierarchy,
strong defaults, every option earns its place:

- **General**: activation (Hold to talk / Tap to toggle / Hybrid — segmented, hybrid default,
  one-line explanations), Launch at login, Sounds, Haptics.
- **Dictation**: Language (Automatic + list from engine), Microphone (System default + list),
  Restore clipboard after insert, "Keep microphone warm" (faster start, shows orange dot —
  off by default, honest explanation).
- **Model**: engine card with status (Ready · 482 MB on disk), re-download, reveal in Finder.
- **About**: version, GitHub link, licenses (FluidAudio Apache-2.0, Parakeet CC-BY-4.0 NVIDIA).

Window ~420 × auto. No scroll if possible.

## Sound & haptics

- Start: short subtle tick (system `Tink.aiff`, volume 0.35).
- Success: system `Pop.aiff`, volume 0.3.
- Error: system `Basso.aiff`, volume 0.3.
- All gated behind `settings.playSounds`. Haptics (`NSHapticFeedbackManager`, `.alignment` on
  start, `.levelChange` on success) behind `settings.hapticFeedback`.

## Micro-copy voice

Short, lowercase-calm, no exclamation marks. "Didn't catch that." · "A secure field is
focused — dictation can't type here." · "Microphone unavailable." English v1.

## App icon

Minimalist: near-black (#141414) rounded-rect (standard macOS squircle canvas, ~10% margin),
five white capsule bars forming a waveform silhouette, center bar tallest. No border, no
gradient (a barely-visible top-to-bottom luminance shift ≤4% is allowed). Must read at 16 px.
