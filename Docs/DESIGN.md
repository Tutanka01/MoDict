# MoDict — Design System

MoDict is a **quiet tool**. It should feel like a native part of macOS that Apple forgot to ship:
monochrome, weightless, instant. No dashboards, no gradients, no mascots. The entire visible
surface of the app is: a menu bar glyph, a floating composition card while you speak, a small onboarding
window, and a settings window. Every one of them must feel inevitable.

## Principles

1. **Invisible until needed.** Zero chrome at rest. The HUD appears on key-down and is gone the
   instant the text lands. Nothing lingers.
2. **Monochrome.** The palette is black, white, and materials. System red is reserved for error
   states (and the menu's recording dot); system orange for the silence warning. Nothing else.
3. **Physics, not tweens.** All motion uses springs. Nothing fades linearly; things scale and
   settle like objects with mass.
4. **Text is the product.** MoDict's output is the user's words in someone else's app. Our UI
   never competes with that, and the HUD shows them where they will land: at the text cursor.
5. **Guidance fades.** The HUD teaches the gesture while it is new, then gets out of the way.
   What a user already knows is never repeated.

## Color & Materials

| Token | Value | Usage |
|---|---|---|
| Surface | HUD: smoked glass — Liquid Glass `.clear` tinted `black 70%` (macOS 26+), or `hudWindow` + `black 50%` (macOS 15), on an always-dark panel; menu bar uses system material |
| Rim | white 26% → 7% vertical gradient | 0.75 pt lit edge on the HUD's macOS 15 fallback only — Liquid Glass carries its own edge |
| Primary | `Color.primary` | Voice waveform, cursor, icons, text |
| Secondary | `Color.secondary` | Captions, hints, timestamps |
| Recording dot | `Color.red.opacity(0.9)` | menu status card only; the HUD's moving waveform is its recording indicator |
| Warning | `Color.orange` | the HUD's silence warning text only |
| Error | `Color.red` | Error icon + label only. Never backgrounds. |
| Shadow | contact `black 20%` r 1.5 y 1 + ambient `black 26%` r 22 y 12 | HUD only: two shadows, like a real object |

Dark and light mode both supported via semantic colors — never hardcode grays.

## Typography

System font only (SF Pro). Sizes:
- Onboarding titles: `.system(size: 26, weight: .semibold)`, tracking −0.5
- Onboarding body: `.system(size: 13)`, `.secondary`
- HUD title (Pasted, errors): `.system(size: 12.5, weight: .semibold)`; hints
  `.system(size: 10.5, weight: .medium)`; preview `.system(size: 14)`, 3 pt line spacing
- Menu bar list items: `.system(size: 13)`
- Settings: 26 pt semibold pane titles, 13 pt descriptions, native grouped `Form` controls.

## The HUD (composition preview)

The single most important surface. A non-activating `NSPanel` presents one continuous surface
of smoked glass that changes shape with what it has to say. It never steals focus and never
writes into the target application while recording.

**Concept: your voice, written at the cursor.** The mark is a waveform whose peak is a text
cursor; the HUD is that mark come alive. Your voice is a waveform beside a cursor, and once
words exist the cursor moves into them and types them as they condense. Every motion is either
your voice (the waveform) or your words (the ink); nothing is decorative.

**Anchor: the text cursor**
- Default position (“At your cursor”, stored as `nearPointer`): on key-down, `TextCaretLocator`
  reads the focused element's insertion point through the Accessibility API (read-only, 40 ms
  messaging timeout per call, never enabling an app's enhanced AX mode). The card hangs
  **8 pt** below the cursor's line with its content starting at the cursor's x, so the preview
  reads where the words will land and grows down and to the right, away from the text. With
  no room below it flips above the line; the fully grown card never crosses the menu bar or
  the camera housing.
- Apps that report no caret (terminals, many Electron apps) fall back to the pointer: centered,
  **78 pt** above it, flipping below near the menu bar and clamping to the visible screen.
- The anchor is frozen for the full recording → transcribing → success/error sequence, so
  typing or moving the mouse never drags the card.
- Bottom-center and top-center remain optional positions in Settings. Edge modes pin the
  card's near edge and grow only toward the free side. Top-center: card top **10 pt** below
  the menu bar, and below the camera housing when the menu bar auto-hides
  (`min(visibleFrame.maxY, frame.maxY − safeAreaInsets.top)`). Bottom-center mirrors it: bottom
  edge fixed **28 pt** above the screen bottom, growth upward.

**Surface: smoked glass**
- macOS 26+: Liquid Glass `.clear` tinted black 70%. It keeps the refraction, the lit edge and
  a faint color of what lies beneath (a warm plum over a vivid wallpaper), while white text
  reads equally over a white page and a black terminal. `.regular` glass was rejected: over a
  light page it renders a flat mid gray (≈ #757575) whatever its tint, and gray-on-gray hints
  fell to ~2:1 contrast.
- macOS 15: AppKit's `hudWindow` material under a 50% black smoke and a lit rim.
- The glass is carried by one stable container, so every state change morphs a single surface;
  two glass layers never cross-fade.
- The panel forces `.darkAqua`: the HUD has one constant identity, like Apple's volume overlay.

**Shape**
- One rounded rectangle, **20 pt** continuous corner radius, for every state. At capsule height
  (**40 pt**: a 22 pt voice row + 2 × 9 pt) that radius is exactly half the height, so capsule ↔
  card is a single morph of one surface.
- **Capsule** while you speak and no words exist yet: the living mark (waveform + cursor), plus
  any active hint, at their natural width.
- **Card** exactly once, when the first preview words arrive: **380 pt** wide and fixed for the
  rest of the session, so the caption's wrap column never changes mid-sentence. It grows one
  line at a time up to three lines; there is never an empty line between the voice row and
  the words.
- **Capsule** again for “Pasted”, which retracts toward its pinned edge (the cursor) on hide.
- Error: **280 pt** card, up to two lines. One **15 pt** leading inset for capsule and card, so
  the waveform never shifts during the morph; an **11 pt** trailing inset when the esc chip ends
  the row, so its corners sit concentric with the capsule's.

**The living mark (waveform + cursor)**
- The waveform: 7 bars (3 pt wide, 3 pt gap, 4–22 pt) in a symmetric arch (0.50 → 1.00 → 0.50).
  Each bar's height follows the microphone level with its own slight wobble (phase and speed
  per bar), so speech reads as lively without a scrolling history; below a 0.03 level the bars
  fall back to a slow breath around their minimum height.
- The level eases toward each microphone reading on the display clock (60/120 Hz, fast attack,
  slower release; `HUDLevelSmoother`), so the bars glide instead of stepping at the ~12 Hz
  buffer rate.
- The cursor sits 6 pt after the waveform (22 pt, as tall as the loudest bar). It blinks with a
  native caret's rhythm (1.06 s, soft plateaus) at rest, and stays solid while you speak or
  while words arrive, exactly as a caret stops blinking while you type
  (`HUDVoiceActivity`). No glow: an earlier voice halo read as smudge.
- Transcribing: the waveform stops listening and eases (0.4 s) into a low ripple running toward
  the cursor; the cursor breathes (1.4 s).
- Reduce Motion: no wobble, breath, ripple or blink; a 5 Hz level meter in the same arch.

**States & content**
| State | Content | Notes |
|---|---|---|
| `recording` | the living mark; hints only when relevant | no title, no dot: the moving waveform is the recording indicator. The stop gesture (“Release to paste”; toggle: “Press again to paste”) and the esc chip show only while `gestureHintsRemaining > 0` (the first 8 successful dictations, reset when the key or activation mode changes; upgraded installs start at 0). Hybrid's switch to hands-free shows “Press again to paste” regardless. The m:ss clock appears after **10 s**. Sustained silence shows an orange “Hearing nothing — check your microphone”. The hint is the only flexible element: it truncates with an ellipsis, the height never changes. Hints change in sequence (old out in 0.06 s, new in), never overlapping |
| `transcribing` | the same view: the waveform ripples, the cursor breathes, a light sweeps the words | releasing changes motion, not structure: recording and transcribing are one branch, so the caption keeps its state. No spinner, no “Preparing” label. The words stay readable (72% floor) under the sweep (drawing-only `TextRenderer`, never layout). Guidance shows “Transcribing” + esc while the gesture is being learned. The target application is still untouched |
| `success` | a check drawn on in one stroke, knocked out of a white disc + “Pasted” + “N words” | capsule, shown ~700 ms then hidden, scaling to 0.9 toward the cursor |
| `error(message)` | contextual red symbol + primary label | up to two lines; shown ~2.2 s |

Between states the choreography runs in sequence: the old content leaves in 0.08 s, the surface
morphs with the state spring, and the new content arrives (0.2 s, 0.1 s delay, from 94% scale).
Two messages never overlap mid-morph.

**Private preview and commit boundary**
- Every model gets a live preview. Parakeet streams its own; for models that don't stream
  (Qwen, cloud), Parakeet runs on this Mac for the preview only, when Settings › Dictation ›
  Live preview is on (default) and its model is on disk. Nothing is downloaded for it, and the
  pasted text always comes from the selected model.
- Streaming is preview-only. `StreamingTranscriptAssembler` merges overlapping rolling
  hypotheses into one cumulative document, preserving the stable prefix and revising only the
  recent boundary. It never consumes FluidAudio’s repeated accumulated transcript.
- On key release/stop, streaming is cancelled. The complete captured utterance is transcribed
  exactly once through the batch manager; only this canonical result can reach `TextInserter`.
- A final repeated-phrase guard collapses adjacent duplicated spans of five or more words before
  vocabulary replacement and paste. Short intentional emphasis remains untouched.

**Ink (the caption)**
- 14 pt regular, leading aligned, ending in the live cursor, which is glued to the last word by a
  no-break space. Confirmed text is `primary 0.95`; the volatile tail is `0.5`, the monochrome
  translation of Apple's provisional-dictation underline, and brightens (0.35 s) when confirmed.
- `HUDInk` stamps each character when it appears and when it is confirmed. A new partial keeps
  the stamps of the unchanged prefix; everything after the first difference is new ink. So new
  words condense out of a blur (5 pt → 0, rising 3.5 pt, 0.5 s per glyph, 18 ms stagger, a
  whole batch within 0.45 s), and a word the recognizer revises visibly rewrites itself.
- The cursor rides the ink front: while glyphs are still arriving it sits one space after the
  last visible glyph, so the words appear typed by your voice instead of the cursor leaping
  ahead of them.
- All of this is drawing only (`HUDCaptionRenderer`, a `TextRenderer` reading custom text
  attributes): each partial is still one deterministic layout pass, and interpolating a live
  caption's layout is what made earlier previews swim.
- The card grows line by line up to three lines (critically damped spring). Beyond three, the
  text is top-pinned and offset by its measured overflow, so each new line glides the older
  ones up through a top fade that eases in at the first overflow. There is no ScrollView and no
  scroll position; a partial arriving mid-glide simply retargets the spring.
- Only the recent tail (~220 chars, cut on a word boundary) is laid out, so cost stays flat on
  long dictations. Stamps older than 1.2 s collapse so settled text renders as a few runs.
- Choreography: key-down → capsule appears at the text cursor → first words grow it into the
  card, the cursor moves into the text → words condense as they are heard → release/stop →
  waveform ripples, words shimmer → canonical text settles, rewriting what changed → one paste →
  check draws on → retracts. Esc cancels with no paste.

**Panel motion**
- Appear: scale 0.92→1.00 + opacity 0→1, `.spring(response: 0.32, dampingFraction: 0.75)`.
  The panel must be visible **on key-down, before any audio arrives** (perceived latency).
- Disappear: opacity + scale to 0.90 toward the pinned edge over 0.18 s ease-out.
- Shape changes between states (capsule ↔ card) animate with the same spring; the one-time
  growth for the preview uses a fully damped spring so the caption baseline never overshoots.
- Error state does a ±4 pt horizontal shake, twice, 0.05 s each.
- Cost: the waveform redraws on the display clock and the caption at 60 Hz, both as `Canvas` /
  renderer draws with no layout pass; a full scripted dictation measures ~20% of one core,
  launch included, and only while the HUD is on screen.

## Menu bar

The status item is the mark, drawn as a template image from `MoDictMark`: the mark at rest,
knocked out of a solid tile while dictating, dimmed when paused; the system's download arrow
while a model downloads.

The 360 pt popover is about your words; status appears only when there is something to know.
- Header: the app glyph and name. When everything is ready, the one thing worth remembering
  sits under the name: the real gesture for the selected key and activation mode.
- A rounded status card appears only when the state is not plain readiness: paused, recording
  or transcribing (with live text), downloading (with progress), or an issue. Download, Retry,
  Resume and open-settings actions appear only when relevant and name their destination
  (Open General settings, Choose a microphone, Review model settings). Error details are
  capped at three lines with the full message available on hover.
- Recent: the last five dictations show two lines of text, a timestamp, optional request
  cost, and a separate, visible Copy action. Copy changes to Copied for 1.5 seconds. The
  ellipsis opens the full, selectable text in a scrollable popover. Rows have a consistent
  76 pt height; the list grows to two rows, then scrolls in a 220 pt viewport with a partial
  third row to reveal more content. Clearing history requires confirmation. Empty history
  explains how to start; populated history states that these copies live only in memory.
- Quiet link rows: the model (**On this Mac** or **Cloud**, and its name) opens Model settings;
  today's cloud spend appears only once spend exists and opens the Usage pane.
- Footer: text-only Settings… (⌘,), Pause or Resume (⌘P), and Quit (⌘Q).

The system window material shows through. Semantic foregrounds, soft neutral cards,
and 10–16 pt spacing keep light and dark appearances consistent.

## Onboarding (first launch)

A single fixed window, 520 × 600, centered, non-resizable, hidden title bar
(`.titlebarAppearsTransparent`, no title). Five named steps with a segmented progress line at the top,
primary button full-width at bottom (`.borderedProminent`, `.controlSize(.large)` — tint
`.primary` monochrome look via `.tint(.primary)`).

1. **Welcome** — the app glyph (the mark), “Less typing. More you.” headline, short local/cloud
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

A native Settings scene built on `NavigationSplitView`: a system sidebar (`List` selection,
Liquid Glass on macOS 26+, keyboard and VoiceOver for free) and scrollable grouped forms.
Preferred size 820 × 680 pt, minimum 780 × 620 pt. A large pane title and a plain statement
of what the pane controls (System Settings' voice, not slogans) anchor each page; the toolbar
title is removed to avoid repeating it. The sidebar footer keeps the mark and the local/cloud
status visible. Menu actions navigate directly to the relevant pane; the last pane is
remembered.

- **General**: a shared shortcut guide, Hold to talk / Tap to toggle / Hybrid segmented
  control, four keyboard-accessible keycaps, Launch at login, and live permission status.
  Keycap selection reconfigures the existing event tap immediately. Globe retains the
  native keyboard-setting conflict hint. Unselected labels remain legible in dark mode.
- **Dictation**: language, microphone, Live preview (Parakeet on this Mac for models that
  don't stream), and clipboard restoration. Unplugged microphones
  retain their selection with an Unavailable device label.
- **Vocabulary**: a clear example in the empty state, editable Heard → Replace with rows,
  remove buttons, and Add rule with automatic focus. Rules persist as they are edited.
- **Model**: current-model summary; local download/use/delete/reveal actions; OpenRouter
  key management and cloud choices. Existing deletion and cloud-privacy confirmations stay.
- **Appearance**: three visual position choices (At your cursor / Bottom / Top), sounds and
  haptics. Position choices expose their selection to assistive technology.
- **Usage**: prominent today/all-time USD spend and total dictation count, per-model
  metrics, optional menu-bar spend, reset confirmation, and reveal in Finder.
- **About**: the app glyph, version, creator attribution, repository link and licenses.

No new dependencies or settings affecting transcription. The app follows the system
appearance; the HUD alone does not — it always renders dark (see "Surface"). Reduce
Motion suppresses setup transitions, HUD scaling/shake, the waveform's wobble and ripple, the
caret blink, the ink entrance and shimmer, and keycap compression. The voice row retains a
slower level meter.

### Surface

The HUD has one constant identity, the way Apple's own transient overlays (volume,
brightness) do: the panel forces a dark appearance (`NSAppearance` `.darkAqua`) and the
card is smoked glass (see "Surface: smoked glass" above), so it reads equally over a
white page and a black terminal. Liquid Glass honors Reduce Transparency automatically;
AppKit renders the macOS 15 material opaque under it. The earlier voice aura and caret
glow are gone: an external halo read as smudge over dark content. The recording dot and
“Listening” title are gone too: the moving waveform is the recording indicator, and macOS
already shows its own microphone indicator.

## Sound & haptics

- Start: short subtle tick (system `Tink.aiff`, volume 0.35).
- Success: system `Pop.aiff`, volume 0.3.
- Error: system `Basso.aiff`, volume 0.3.
- All gated behind `settings.playSounds`. Haptics (`NSHapticFeedbackManager`, `.alignment` on
  start, `.levelChange` on success) behind `settings.hapticFeedback`.

## Micro-copy voice

Short, lowercase-calm, no exclamation marks. "Didn't catch that." · "A secure field is
focused — dictation can't type here." · "Microphone unavailable." English v1.

## The mark and the app icon

The mark is a voice waveform whose peak is a text cursor (I-beam): your voice goes in, your
words come out where the cursor is. Five elements, vertically symmetric: bars at 30% and 56%
of the mark's height, then an I-beam at 86% with a thin stem and short serifs, then the
mirrored bars. `MoDictMark` (`Sources/MoDict/UI/Mark.swift`) is the single source of truth for
the in-app glyph (`AppGlyph`: the mark knocked out of a solid continuous-corner tile) and the
menu bar template images. `Support/generate-icon.swift` and `Support/AppIcon.icon` reproduce
the same proportions; keep all three in sync.

- **Liquid Glass icon** (`Support/AppIcon.icon`, Icon Composer format): a near-black fill
  (#141414) and two glass groups, the voice bars behind and the cursor in front, each with a
  neutral shadow and light translucency. `make bundle` compiles it with `actool` into
  `Assets.car` (light, dark, tinted and clear appearances on macOS 26+) plus a matching
  `AppIcon.icns` for macOS 15, and sets `CFBundleIconName`.
- **Flat fallback** (`generate-icon.swift`): the same mark in white on a near-black squircle
  with a ~10% margin and a ≤4% luminance shift, used whenever `actool` cannot compile the
  layered icon. Must read at 16 px.
