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
