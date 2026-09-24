# Releases

Every entry here corresponds to a git tag `vX.Y.Z`. Pushing the tag triggers
[release.yml](.github/workflows/release.yml), which runs the tests, builds the app,
and publishes `MoDict-X.Y.Z.dmg` on the
[Releases page](https://github.com/Tutanka01/MoDict/releases). Newest first.

<!-- Template for a new entry:

## vX.Y.Z — YYYY-MM-DD

- Highlight 1
- Highlight 2
-->

## v0.8.0 — 2026-09-24

Your words, at your cursor: the HUD moves to where the text will land, every
model gets a live preview, and MoDict gets a mark of its own.

- **The preview hangs under your text cursor.** On key-down MoDict reads the
  focused field's insertion point (read-only Accessibility, 40 ms timeout) and
  hangs the HUD just below that line, the words starting at the cursor's x and
  growing down and to the right, away from what you are writing. It flips above
  the line near the bottom of the screen; apps that report no caret (terminals,
  many Electron apps) fall back to the pointer. The anchor never moves during a
  session.
- **Live preview for every model.** Qwen3-ASR and cloud models don't stream;
  when Parakeet is on disk it now transcribes a preview on this Mac while you
  speak (Settings → Dictation → Live preview, on by default). Nothing is
  downloaded for it, nothing extra leaves your Mac, and the pasted text still
  comes from the selected model.
- **Words that write themselves.** New words condense out of a blur behind a
  live cursor, a word the recognizer revises visibly rewrites itself, tentative
  words brighten when confirmed, and past three lines the older ones glide up
  through a fade. All of it is drawing only: each partial is still one layout
  pass, so the caption never swims.
- **One glass surface.** The HUD is a capsule while you speak, grows once into a
  card when words arrive (fixed width, so the caption never rewraps), and turns
  back into a capsule for "Pasted", with a check that draws itself. Smoked
  Liquid Glass on macOS 26 (the `hudWindow` material on macOS 15), always dark,
  so it reads over a white page and a black terminal alike. The waveform and a
  blinking text cursor replace the voice aura and the recording dot; the level
  now glides at 60/120 Hz instead of stepping with each audio buffer.
- **Guidance fades.** The stop gesture and the esc chip show for your first 8
  dictations, then step aside; they come back when you change the key or the
  activation mode (upgraded installs start without them). The m:ss clock
  appears only after 10 s. The silence warning now fires after 2.5 s of real
  silence instead of about 6 s, and still clears on the first syllable.
- **A mark of its own**: a voice waveform whose peak is a text cursor. It is the
  menu bar icon (knocked out of a tile while dictating, dimmed when paused),
  the glyph in Settings and onboarding, and a layered Liquid Glass app icon on
  macOS 26 (light, dark, tinted and clear styles).
- **A quieter menu and Settings.** The popover leads with your recent
  dictations; the status card appears only when there is something to know
  (paused, recording, downloading, an issue). Settings moves to a native
  sidebar with plain descriptions of what each pane controls.
- Reduce Motion: no wobble, ripple, caret blink, ink entrance or shimmer; the
  voice row stays a slow level meter.

Requires macOS 15+ on Apple Silicon. Local builds keep the `MoDict Dev`
signing identity and the `com.modict.app` bundle ID, so TCC permissions,
models and history survive the update.

## v0.7.0 — 2026-09-20

The interface refresh release: the menu bar, Settings, onboarding and the HUD
were rebuilt around one idea — a quiet tool that answers you.

- **A menu bar that acts, not just reports**: the status card now names the
  exact problem and the fix (Download model, Retry setup, Resume dictation,
  Open General settings, Choose a microphone, Review model settings), the
  model row and today's cloud spend open the right Settings pane directly,
  and the recent list is scrollable with a full-text popover and a
  confirmation dialog before clearing. A footer holds Settings (⌘,), Pause
  Dictation (⌘P) and Quit.
- **Settings gets a sidebar**: seven panes — General, Dictation, Vocabulary,
  Appearance, Model, Usage, About — with a per-pane subtitle, large usage
  metrics, and a dedicated Appearance pane (HUD position with visual cards,
  sounds, haptics). Deep links from the menu bar land on the right pane.
- **Setup is a real onboarding**: labeled step progress, one shared
  ShortcutGuide that states the actual gesture for your key and activation
  mode, arrow-key navigation, and a pre-focused trial editor.
- **The HUD answers you**: a soft monochrome voice aura swells with your
  speech, a m:ss clock counts the recording, Pasted reports the word count
  ("Pasted · 24 words"), and a silence watchdog warns "Hearing nothing —
  check your microphone" before a long dictation transcribes to nothing —
  then recovers on the first syllable. Success and error states are
  announced to VoiceOver.
- **Settings windows behave like normal windows again**: resizable (a
  SwiftUI `Settings`-scene limitation, worked around), and MoDict appears in
  the Dock and ⌘-tab while a window is open, returning to a pure menu-bar
  citizen on close.
- Reduce Motion is respected everywhere: no aura, no shake, no transitions,
  and the waveform timeline pauses instead of repainting a still frame.

Requires macOS 15+ on Apple Silicon. Local builds keep the `MoDict Dev`
signing identity and the `com.modict.app` bundle ID, so TCC permissions,
models and history survive the update.

## v0.6.0 — 2026-09-19

- **Cloud usage and cost tracking**: every OpenRouter response reports the exact
  charge for that request, and MoDict now keeps a local ledger of dictations,
  audio duration, tokens, and spend. Settings → Usage shows today's and
  all-time totals plus a per-model breakdown, the menu bar can show spend next
  to its icon (off by default), and each cloud dictation in the recent list
  shows what it cost. Metrics only — transcription text never reaches the
  ledger.
- **No more macOS Keychain password prompts**: the OpenRouter key is stored in a
  user-only (0600) file under `~/Library/Application Support/MoDict` instead of
  the login Keychain. macOS identifies a self-signed build by the hash of the
  binary, which changes on every rebuild, so it asked for the login password on
  every Keychain read — at launch and before each cloud dictation. Upgrading
  from 0.5.x: paste your key once in **Settings → Model**; the old "MoDict
  OpenRouter API key" item is no longer read and can be deleted in Keychain
  Access.
- Settings gains a **Usage** tab (spend, per-model stats, menu-bar picker,
  reveal/reset for the ledger file), and the cloud-privacy copy now states that
  costs come from the provider's own report.

## v0.5.1 — 2026-09-19

- Cloud dictation survives temporary OpenRouter congestion: rate limits and
  provider hiccups (429/502/503/524/529) are retried up to three times with
  exponential backoff, and a short `Retry-After` hint from the server is
  honoured. Invalid keys, missing credits, and other permanent errors still
  fail immediately with an actionable message.
- **Settings → Model** is easier to read: a summary card shows the model in
  use and where audio goes, the OpenRouter key section now sits above the
  cloud models, and every model has its own **Use** button instead of one
  shared picker. Cloud choices stay disabled until a key is saved.
- Settings uses native grouped forms at 560 × 540, with semantic fonts and
  colors in light and dark mode. Vocabulary rows are plain text fields with
  an always-visible remove button that works with keyboard and pointer.
- README and the design/QA docs match the new Model tab.

## v0.5.0 — 2026-09-19

- Optional cloud transcription through OpenRouter: choose **MAI-Transcribe 2**,
  **Muse Voice Transcribe 1.0**, or **GPT Transcribe** alongside the two local
  models. Local transcription remains the default and keeps audio on this Mac.
- Cloud use is explicit: MoDict shows the privacy and cost warning before the
  switch, sends audio only after the recording ends, limits cloud recordings to
  10 minutes, and blocks dictation until an API key is available.
- OpenRouter API keys are stored in the macOS login Keychain, never in
  UserDefaults, logs, or the request body. Keys can be replaced or removed from
  Settings → Model.
- Updated onboarding, settings, menu-bar status, privacy copy, architecture
  notes, and QA coverage for the local/cloud model split.

## v0.4.1 — 2026-09-17

- Fixed the v0.4.0 download: its app could not initialize the MLX runtime
  ("Failed to load the default metallib"), so Qwen3-ASR dictation failed even
  though the model had downloaded correctly. The bundle now ships MLX's Metal
  kernel library, and both CI workflows run a real MLX kernel on the packaged
  app before it can be published. Parakeet v3 was unaffected.
- The v0.4.0 release page was withdrawn; this is the same feature release with
  a working Qwen3-ASR runtime.

## v0.4.0 — 2026-09-17

- New default speech model: **Qwen3-ASR 1.7B** (4-bit, running locally through
  MLX) for stronger French and multilingual transcription. Fresh installs
  download it from Hugging Face on first run (~2.3 GB); existing installs keep
  the model they already have and download nothing unless asked.
- **Settings → Model** now manages both models: pick the active one, download,
  delete, or reveal it in Finder, with per-model status, size, and progress.
  Deleting a model frees its disk space without touching your settings.
- **Parakeet v3** stays one pick away: smaller (~482 MB), faster, runs on the
  Neural Engine, and it is still the only model with the live transcript
  preview in the HUD. Qwen transcribes once, after you release the key.
- Requires **macOS 15** or later. Building from source now needs **Xcode 16+**,
  because SwiftUI's macros only ship with the full Xcode toolchain.
- Packaging: the app bundle now embeds the MLX runtime (`Cmlx.framework`) and
  the matching code-signing entitlement, so the distributed `.app` starts from
  any location, including a quarantined download.
- Everything else is unchanged: on-device only, no telemetry, clipboard
  restored after insert, history in memory only.

## v0.3.0 — 2026-09-13

- French transcription overhaul: the language you pick is now pinned on the
  live preview as well as the final pass, which activates FluidAudio's
  French anti-English decoder guard. Long dictations no longer drift into
  English at window boundaries, and short utterances are decoded with the
  same language context everywhere.
- "Automatic" now follows your Mac's language when MoDict supports it;
  picking a language explicitly still wins.
- Audio conditioning before transcription: utterances are trimmed to their
  speech bounds instead of padding with digital silence, quiet recordings
  are lifted with a peak-guarded gain, and DC/rumble below 60 Hz is removed.
  If a trim ever leaves nothing to decode, the untouched take is retried.
- The recording cue plays before the microphone opens, so the first word is
  no longer captured together with the chime, and the last audio buffer is
  drained at key release instead of being cut off.
- Vocabulary rules now match across accents in both directions, so a rule
  typed without accents still catches "résumé" (and vice versa).
- Dependency: FluidAudio 0.15.7. Also raises the input converter to the
  highest-quality profile.

## v0.2.0 — 2026-07-13

- Live transcription in the HUD: the composition card shows a rolling
  three-line preview of what you are saying, updated about once per second
  while you speak. Confirmed text is primary, the still-volatile tail is
  secondary; the pasted text still comes from the full-utterance pass.
- The preview is a bottom-pinned caption window (no scrolling machinery):
  the newest words sit on a fixed baseline and older lines glide up through
  a constant top fade — no more erratic jumps while dictating.
- The card keeps one width for the whole session, and edge positions are
  anchored: top-center pins the card just below the menu bar (and below the
  camera housing on notched MacBooks, even with the menu bar hidden) and
  grows downward only; bottom-center mirrors it upward.
- Streaming merge hardened: hypothesis fragments are anchored on at least
  three shared words or appended with boundary deduplication, so the live
  preview can no longer cut sentences in half or momentarily empty and
  refill during long dictations.
- A repeated-phrase guard collapses accidentally duplicated spans (five or
  more words) before anything is pasted.
- Custom vocabulary replacements (Settings → Dictation) apply to both the
  live preview and the pasted text.

## v0.1.2 — 2026-07-09

- Fixed the Input Monitoring system prompt re-appearing on every launch (startup
  now only preflights; the prompt is raised solely by an explicit user action).
- Permission state now updates live while the app runs: the event tap re-arms and
  stale menu-bar issues clear as soon as a grant appears in System Settings —
  no relaunch needed.
- New Permissions section in Settings → General showing the live status of
  Microphone, Accessibility and Input Monitoring, with shortcuts to grant them.
- Onboarding no longer re-opens after setup when a permission is missing; the
  menu-bar status reports it instead.
- Info.plist copyright corrected to AGPL-3.0.

## v0.1.1 — 2026-07-09

- Same contents as v0.1.0 (re-tag).

## v0.1.0 — 2026-07-09

- Initial release: hold right ⌘ to dictate anywhere, on-device transcription with
  Parakeet-TDT v3 on the Neural Engine, menu-bar-only app, no telemetry.
