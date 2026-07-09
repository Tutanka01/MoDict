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
