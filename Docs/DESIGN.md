# MoDict — Design System

MoDict is a **quiet tool**. It should feel like a native part of macOS that Apple forgot to ship:
monochrome, weightless, instant. No dashboards, no gradients, no mascots. The entire visible
surface of the app is: a menu bar glyph, a floating composition card while you speak, a small onboarding
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
| Surface | `.regularMaterial` | HUD composition card; menu bar uses system material |
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
- Settings: 28 pt semibold pane titles, 13 pt descriptions, native grouped `Form` controls.

## The HUD (composition preview)

The single most important surface. A non-activating `NSPanel` presents a small composition card
near the pointer captured on key-down. It never steals focus and never writes into the target
application while recording.

**Geometry**
- Rounded rectangle, **16 pt** continuous corner radius, `.regularMaterial`, hairline and shadow.
- Session (listening/transcribing) width: **380 pt** — one width whether or not the preview is
  visible, so the caption's wrap column never changes mid-dictation. Success: **118 pt**.
  Error: **280 pt**.
- Default position: centered above the pointer, with a **78 pt** center offset; it flips below
  near the menu bar and clamps to the visible screen. The anchor is frozen for the full
  recording → transcribing → success/error sequence, so mouse movement never drags the card.
- Bottom-center and top-center remain optional positions in Settings. Existing installations
  migrate once to near-pointer, then later user choices are preserved.
- Edge modes pin the card's near edge and grow only toward the free side. Top-center: card top
  sits **10 pt** below the menu bar — and below the camera housing when the menu bar auto-hides
  (`min(visibleFrame.maxY, frame.maxY − safeAreaInsets.top)`) — and the preview expands
  downward only, so the card can never enter the notch band. Bottom-center mirrors it: bottom
  edge fixed **28 pt** above the screen bottom, growth upward. Near-pointer clamps the fully
  grown card (not just the panel) below the same safe top.

**States & content**
| State | Content | Notes |
|---|---|---|
| `recording` | red pulse + 7 waveform bars, “Listening”, and the exact stop gesture | “Release to paste” for Hold; hands-free changes to “Press again to paste” |
| `transcribing` | 3 dots, “Preparing paste”, “Esc to cancel”, and the last preview | the target application is still untouched |
| `success` | `checkmark.circle.fill` + “Pasted” | shown ~700 ms then hidden |
| `error(message)` | contextual red symbol + primary label | up to two lines; shown ~2.2 s |

**Private preview and commit boundary**
- Streaming is preview-only. `StreamingTranscriptAssembler` merges overlapping rolling
  hypotheses into one cumulative document, preserving the stable prefix and revising only the
  recent boundary. It never consumes FluidAudio’s repeated accumulated transcript.
- The preview is 13 pt regular and leading aligned inside a fixed **three-line viewport**,
  rendered as one bottom-pinned, top-clipped text block — not a ScrollView. The newest words
  sit on a fixed bottom baseline; when a line wraps, older lines shift up through a constant
  transparent → opaque top fade. There is no scroll position and no per-partial animation:
  each update is a single deterministic layout pass (interpolating a live caption is what
  makes it swim). Confirmed text is `primary 0.92`; the volatile tail is `secondary` — the
  monochrome translation of Apple's provisional-dictation underline. Only the recent tail
  (~220 chars, cut on a word boundary) is laid out, so cost stays flat on long dictations.
- On key release/stop, streaming is cancelled. The complete captured utterance is transcribed
  exactly once through the batch manager; only this canonical result can reach `TextInserter`.
- A final repeated-phrase guard collapses adjacent duplicated spans of five or more words before
  vocabulary replacement and paste. Short intentional emphasis remains untouched.
- Choreography: key-down → card appears → rolling preview updates → release/stop → “Preparing
  paste” → canonical text settles → one paste → “Pasted” → hide. Esc cancels with no paste.

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

The 360 pt popover is a compact place to check readiness and recover your words.
- App mark and a labeled Pause / Resume button.
- A rounded status card: the real gesture for the selected key and activation mode,
  live text during dictation, download progress, or the current issue. Download, Retry,
  Resume and Review settings actions appear only when relevant. Error details are capped
  at three lines with the full message available on hover.
- A model row states **On this Mac** or **Cloud** and opens Model settings directly.
- The last five dictations show two lines of text, a timestamp, optional request cost,
  and a visible Copy action. Copy changes to Copied for 1.5 seconds. The ellipsis opens
  the full, selectable text in a scrollable popover. The list scrolls at 320 pt so the
  footer stays reachable on smaller screens. Clearing history requires confirmation.
- Empty history explains how to start; populated history states that these copies live
  only in memory for the current session.
- Today's cloud spend appears only once spend exists and opens the full Usage pane.
- Labeled Settings and Quit actions support Command-comma and Command-Q.

The system window material shows through. Semantic foregrounds, soft neutral cards,
and 10–16 pt spacing keep light and dark appearances consistent.

## Onboarding (first launch)

A single fixed window, 520 × 600, centered, non-resizable, hidden title bar
(`.titlebarAppearsTransparent`, no title). Five named steps with a segmented progress line at the top,
primary button full-width at bottom (`.borderedProminent`, `.controlSize(.large)` — tint
`.primary` monochrome look via `.tint(.primary)`).

1. **Welcome** — shared app glyph, “Less typing. More you.” headline, short local/cloud
   explanation, and a physical keycap with the actual gesture for the current activation mode.
   Creator attribution remains below the primary action.
2. **Microphone** — why + button "Allow microphone" → `AVCaptureDevice.requestAccess`.
   Card flips to granted state with checkmark automatically.
3. **Accessibility & Input Monitoring** — two permission cards, each with status and an
   "Open Settings" action; auto-advance polling. Copy: "To detect the right ⌘ key and type
   text into your apps. MoDict never logs your keystrokes."
4. **Speech model** — Qwen3-ASR 1.7B by default; local and cloud models are selectable.
   Local models show download size and progress. Cloud selection needs a privacy confirmation,
   persistent warning, and a SecureField for an OpenRouter key stored locally.
5. **Try it** — an automatically focused `TextEditor` with mode-aware gesture instructions.
   Arrow keys remain available for text editing; Command-[ goes back. On first successful insertion:
   checkmark spring animation + "That's it. MoDict lives in your menu bar."
   Button "Start dictating" closes onboarding.

Each step: SF Symbol in a 56 pt circle (`.ultraThinMaterial` fill), title, one short paragraph,
action. Nothing else. Steps advance automatically when their condition is met.

## Settings

A native Settings scene with a 208 pt sidebar and scrollable grouped forms. Preferred
size 820 × 680 pt, minimum 780 × 620 pt. A large pane title and short purpose statement
anchor each page. The sidebar keeps the selected model and local/cloud status visible.
Menu actions navigate directly to the relevant pane; the last pane is remembered.

- **General**: a shared shortcut guide, Hold to talk / Tap to toggle / Hybrid segmented
  control, four keyboard-accessible keycaps, Launch at login, and live permission status.
  Keycap selection reconfigures the existing event tap immediately. Globe retains the
  native keyboard-setting conflict hint. Unselected labels remain legible in dark mode.
- **Dictation**: language, microphone, and clipboard restoration. Unplugged microphones
  retain their selection with an Unavailable device label.
- **Vocabulary**: a clear example in the empty state, editable Heard → Replace with rows,
  remove buttons, and Add rule with automatic focus. Rules persist as they are edited.
- **Model**: current-model summary; local download/use/delete/reveal actions; OpenRouter
  key management and cloud choices. Existing deletion and cloud-privacy confirmations stay.
- **Appearance**: three visual position choices (Near pointer / Bottom / Top), sounds and
  haptics. Position choices expose their selection to assistive technology.
- **Usage**: prominent today/all-time USD spend and total dictation count, per-model
  metrics, optional menu-bar spend, reset confirmation, and reveal in Finder.
- **About**: shared mark, version, creator attribution, repository link and licenses.

No new dependencies or settings affecting transcription. The app follows the system
appearance. Reduce Motion suppresses setup transitions, HUD scaling/shake, animated
transcribing dots and keycap compression. The recording waveform retains a slower,
non-oscillating level update. The HUD shows an Esc cancellation hint and preserves its
existing non-activating panel, stable preview width and screen-edge anchoring.

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
