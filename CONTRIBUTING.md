# Contributing to MoDict

Thanks for helping. MoDict aims to feel like a native part of macOS that Apple forgot to
ship: monochrome, weightless, instant. Keep that spirit in code and in copy, and read the
two design documents before you write anything:

- [Docs/ARCHITECTURE.md](Docs/ARCHITECTURE.md) — modules, the state machine, and the
  **frozen** public contracts.
- [Docs/DESIGN.md](Docs/DESIGN.md) — the visual system, motion, and micro-copy voice.
- [Docs/QA.md](Docs/QA.md) — the pre-prod P1 checklist for permissions, signing,
  insertion, devices, sleep/wake, clipboard, model readiness, and privacy.

## Setup

MoDict builds with pure SwiftPM and the Command Line Tools. You do **not** need Xcode.

**Prerequisites**

- macOS 14 (Sonoma) or later, on Apple Silicon.
- Xcode Command Line Tools, which include the Swift 6 toolchain:

  ```sh
  xcode-select --install
  swift --version   # expect Swift 6.x
  ```

**Build and run**

```sh
git clone https://github.com/Tutanka01/MoDict.git
cd MoDict
swift build                 # compile only
make                        # assemble a universal MoDict.app into build/
make run                    # build, sign, and launch it
```

The `Makefile`, `Info.plist.in`, entitlements, icon script, and CI workflow are owned by
the **packaging** module. `make` fetches FluidAudio, builds a universal binary, and
hand-assembles the `.app` bundle (there is no `.xcodeproj`).

### Stable signing for permissions

macOS ties the three TCC permissions (Microphone, Input Monitoring, Accessibility) to the
app's code-signing identity. An **ad-hoc** signature changes its designated requirement on
every rebuild, so macOS re-prompts for all three permissions each time you build. For a
smooth dev loop, create a stable self-signed identity **once**:

```sh
./scripts/dev-cert.sh
```

If the script cannot create it automatically, do it by hand:

1. Open **Keychain Access → Certificate Assistant → Create a Certificate**.
2. Name it `MoDict Dev`, Identity Type **Self-Signed Root**, Certificate Type
   **Code Signing** (check "Let me override defaults").
3. Mark it **Always Trust** for code signing.
4. Confirm it is visible:

   ```sh
   security find-identity -v -p codesigning   # should list "MoDict Dev"
   ```

`make` signs with that identity by default, so permissions now persist across rebuilds.
Without the certificate, fall back to ad-hoc (`make sign IDENTITY=-`) and expect to re-grant
permissions after each build.

MoDict is intentionally **not** sandboxed — posting synthetic key events into other apps
and monitoring a global key are incompatible with the App Sandbox, which is why it ships
outside the Mac App Store.

## Architecture and file ownership

Every file has exactly **one owner**, and each module's public API is **frozen** in
[Docs/ARCHITECTURE.md](Docs/ARCHITECTURE.md#frozen-public-contracts). The rules:

- **Do not edit files you don't own.** If your change needs a different module's API,
  raise it in an issue first — the contract is shared by everyone building in parallel.
- **Implement frozen signatures exactly.** Add `private`/`fileprivate` helpers freely.
- Everything lives in one Swift target. Any type not named in a contract must be
  `private`/`fileprivate` or prefixed with its module name, to avoid collisions.
- `DictationController` is the only place that mutates dictation state and owns the
  robustness rules (stale-result dropping, the 0.35 s minimum utterance, the guarantee
  that the HUD always hides). Don't duplicate that logic elsewhere.

The module map (owners in brackets) lives at the top of the architecture doc; skim it
before picking up work so you know which slice you're touching.

## Code style

- Swift 6 toolchain, **language mode v5**. Write clean concurrency so a later strict-mode
  migration is easy, but don't fight the checker.
- `async/await` throughout. UI and `DictationController` are `@MainActor`; the
  transcription engine is an `actor`; audio-tap callbacks are lock-protected and never
  touch UI directly. The `CGEventTap` callback stays trivial — flip a primitive, then
  `DispatchQueue.main.async` out.
- UI is monochrome and minimal, strictly per [Docs/DESIGN.md](Docs/DESIGN.md): system
  font, `.ultraThinMaterial`, springs (not linear fades), red only for errors and the
  recording dot.
- UI copy is English, calm, lowercase-steady, and uses **no exclamation marks**
  ("Didn't catch that." · "Microphone unavailable.").
- Comments are sober and reserved for non-obvious constraints — a production bug, a timing
  requirement, an API quirk. Don't narrate what the code already says.
- Match the surrounding formatting. No new dependencies without discussion; MoDict has
  exactly one (FluidAudio, pinned exactly).

## Testing the pipeline by hand

There is no substitute for driving the real app. After `make run`, grant the three
permissions and let the model download, then walk the full path in a plain
**TextEdit** window:

1. **Happy path** — click into the text field, hold right ⌘, speak a sentence, release.
   The capsule must appear on key-down (before audio), the waveform must track your voice,
   the state must morph to the transcribing dots, the text must paste at the cursor, and a
   check must flash before the capsule disappears.
2. **Accidental tap** — tap and release right ⌘ in well under a second. Nothing should
   record or insert; the capsule vanishes silently.
3. **Silence** — hold, say nothing, release. Expect the transient "Didn't catch that."
   and no insertion.
4. **Cancel** — start recording, press **Esc**. The session cancels and nothing is
   inserted.
5. **Secure field** — trigger dictation while a password field (or the login window) is
   focused. Text must not be typed; the HUD explains the secure field and the words land
   in menu bar history instead.
6. **Modes** — repeat the happy path in each activation mode (Hold to talk / Tap to
   toggle / Hybrid) from Settings → General.
7. **Device change** — start recording, then connect or switch to AirPods mid-utterance;
   capture should recover rather than crash.
8. **Permissions** — revoke a permission in System Settings and confirm the error surfaces
   inline in the capsule (never a modal), with a way to fix it.

If your change touches packaging, also confirm the bundle is universal:

```sh
swift build -c release --arch arm64 --arch x86_64
lipo -info build/MoDict.app/Contents/MacOS/MoDict   # -> x86_64 arm64
```

Before a pre-prod build, run the broader P1 pass in [Docs/QA.md](Docs/QA.md).

## Pull requests

- Fork, branch from `main`, and keep each PR to **one concern**. Small and reviewable
  beats sweeping.
- Respect file ownership. A PR that edits a module you don't own will be asked to split.
- Make sure it builds and bundles cleanly:

  ```sh
  swift build -c release --arch arm64 --arch x86_64
  make
  ```

- In the PR description, say what you changed and **how you tested it by hand** (which of
  the steps above you exercised). Include a short screen capture for anything visual.
- CI must be green. Write commit messages in the imperative mood ("Add hybrid-mode
  cooldown"), with a body when the reasoning isn't obvious.
- Keep the tone of issues and reviews calm and specific — the same voice the app uses.

By contributing, you agree that your contributions are licensed under the project's
[GNU AGPL-3.0 license](LICENSE). In short: anyone may use, study, and modify MoDict,
but anything built on top of it must stay open source under the same license and keep
the original credits.
