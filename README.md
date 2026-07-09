# MoDict

**Hold right ⌘. Speak. Your words appear wherever your cursor is — 100% on-device.**

MoDict is a quiet, local dictation tool for macOS. Press and hold the right Command
key, say something, let go, and the text is typed into whatever app is focused — your
editor, your browser, a chat box, a terminal. Transcription runs on the Apple Neural
Engine. No cloud, no account, no telemetry. An open-source alternative to Wispr Flow and
superwhisper, built to disappear until you need it.

[![CI](https://github.com/Tutanka01/MoDict/actions/workflows/build.yml/badge.svg)](https://github.com/Tutanka01/MoDict/actions/workflows/build.yml)
[![Release](https://img.shields.io/github/v/release/Tutanka01/MoDict?color=555)](https://github.com/Tutanka01/MoDict/releases/latest)
[![License: AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-555.svg)](LICENSE)
[![Platform: macOS 14+](https://img.shields.io/badge/platform-macOS%2014%2B%20·%20Apple%20Silicon-555.svg)](#requirements)

<!-- TODO(docs): replace with a real capture of the recording HUD over a text editor -->
<p align="center">
  <img src="Docs/assets/hud.png" alt="The MoDict capsule while recording, floating above a text editor" width="440">
</p>

## Why MoDict

- **Your voice never leaves your Mac.** Audio is captured, transcribed, and discarded
  locally. Nothing is uploaded, logged, or sent anywhere.
- **Fast because it runs on the Neural Engine.** MoDict uses
  [Parakeet-TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) via
  [FluidAudio](https://github.com/FluidInference/FluidAudio) and CoreML on the ANE.
  Short utterances transcribe in tens of milliseconds after you release the key —
  no round trip, no 1–2 second cloud lag.
- **25 languages.** Parakeet v3 is multilingual; pick one or let MoDict detect it.
- **It stays out of the way.** A floating capsule appears the moment you press the key
  and vanishes the instant the text lands. No dashboard, no window, no Dock icon —
  just a menu bar glyph.

## Requirements

- macOS 14 (Sonoma) or later
- Apple Silicon (the Parakeet model runs on the Neural Engine)
- ~482 MB of disk for the speech model (downloaded once, on first run)

## Install

### Option 1 — Download the DMG (recommended)

1. Download `MoDict-x.y.z.dmg` from the
   [latest release](https://github.com/Tutanka01/MoDict/releases/latest).
2. Open the DMG and drag **MoDict** onto the **Applications** folder.
3. The build is not yet notarized by Apple, so macOS quarantines it. Clear the flag
   once in Terminal:

   ```sh
   xattr -dr com.apple.quarantine /Applications/MoDict.app
   ```

   Without this step macOS shows *"MoDict is damaged and can't be opened"* — that
   message is Gatekeeper's wording for "unsigned download", not actual damage.
4. Launch MoDict. Onboarding walks you through the three permissions and the one-time
   speech-model download.

### Option 2 — Build from source

Command Line Tools are enough — you do **not** need Xcode.

```sh
xcode-select --install          # if you don't already have the CLT
git clone https://github.com/Tutanka01/MoDict.git
cd MoDict
make            # builds, bundles, and signs build/MoDict.app
make run        # builds and launches it
make dmg        # optional: package the app into build/MoDict-<version>.dmg
```

The first launch asks for the three permissions described below. If you plan to rebuild
often, sign with a stable certificate so the permissions persist across builds — see
[CONTRIBUTING.md](CONTRIBUTING.md#stable-signing-for-permissions).

### Uninstall

MoDict keeps almost nothing on disk. To remove it completely:

```sh
rm -rf /Applications/MoDict.app
rm -rf ~/Library/Application\ Support/FluidAudio   # the downloaded speech model
defaults delete com.modict.app                     # settings
```

## First launch

MoDict asks for three system permissions. Each one maps to a single, visible job:

- **Microphone** — to record your speech. The audio is transcribed on-device and then
  thrown away.
- **Input Monitoring** — to notice when you press and release the right ⌘ key. MoDict
  watches for that one key; it does not read or store what you type.
- **Accessibility** — to paste the finished text into the app you're using, via a
  synthetic ⌘V at your cursor.

To be plain about what MoDict does **not** do: it is not a keylogger — the key monitor
only tracks the right ⌘ (and swallows Esc while you're recording, so you can cancel).
It makes no network connections at all, except a one-time download of the speech model
from Hugging Face.

## Usage

Three activation styles (set in Settings → General; **Hybrid** is the default):

- **Hold to talk** — hold right ⌘, speak, release to transcribe.
- **Tap to toggle** — tap right ⌘ to start, tap again to stop.
- **Hybrid** — hold for push-to-talk; a quick tap switches to hands-free until you tap
  again.

Press **Esc** while recording to cancel — nothing is inserted. The last five
transcriptions live in the menu bar popover; click one to copy it again.

## Troubleshooting

- **"MoDict is damaged and can't be opened."** The download is quarantined because the
  build isn't notarized yet. Run
  `xattr -dr com.apple.quarantine /Applications/MoDict.app` and open it again.
- **Nothing happens when I hold right ⌘.** Check System Settings → Privacy & Security →
  Input Monitoring and Accessibility: MoDict must be enabled in both. If you rebuilt
  from source, macOS may have revoked the grants — toggle them off and on.
- **Text lands in the wrong app.** The paste goes to whichever window has keyboard
  focus when transcription finishes; click into the target field before releasing the
  key.
- **The model download stalls.** It comes from Hugging Face (~482 MB, one time). Use
  Settings → Model → Re-download after checking your connection.

## How it works

1. A `CGEventTap` watches the right ⌘ key and starts capturing 16 kHz mono audio through
   `AVAudioEngine`.
2. On release, Parakeet-TDT v3 transcribes the clip on the Neural Engine and returns
   text in tens of milliseconds.
3. The text is placed on the pasteboard, pasted with a synthetic ⌘V at your cursor, and
   your previous clipboard is restored.

The state machine, module boundaries, and the pitfalls behind each of these steps are
documented in [Docs/ARCHITECTURE.md](Docs/ARCHITECTURE.md).

## Privacy

- Audio never leaves your Mac. Transcription runs entirely on the Apple Neural Engine.
- No telemetry, no analytics, no accounts, no background phone-home.
- The only network request is the one-time model download (~482 MB) from Hugging Face.
- Transcription history (last five items) is kept in memory only and is never written to
  disk.
- The clipboard is snapshotted before each insert and restored afterward.

## Releases

Every version tag pushed to this repository triggers a
[release workflow](.github/workflows/release.yml) that runs the test suite, builds the
app, packages it into a DMG, and publishes it on the
[Releases page](https://github.com/Tutanka01/MoDict/releases) — so what you download is
exactly what CI built from the tagged source. Builds are currently ad-hoc signed;
Developer ID signing and notarization are planned, which will remove the quarantine
step above.

## License & attribution

MoDict is free software, licensed under the
[GNU Affero General Public License v3.0](LICENSE) (AGPL-3.0). You can use, study,
modify, and redistribute it — but any derivative or application built on top of it must
be released under the same license, with source available and the original credits
kept. Closed-source forks and uncredited rebrands are not permitted.

MoDict builds on the work of others; attribution is required:

| Component | License |
|---|---|
| MoDict | [AGPL-3.0](LICENSE) |
| [FluidAudio](https://github.com/FluidInference/FluidAudio) | Apache-2.0 |
| [Parakeet-TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) model weights | CC-BY-4.0 — © NVIDIA |

The Parakeet-TDT 0.6B v3 weights are distributed by NVIDIA under
[CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/); using them requires crediting
NVIDIA, which this project does here and in Settings → About.

## Credits

MoDict is created and maintained by **Mohamad El Akhal**.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for setup, code style, file ownership, and how to
test the full dictation pipeline by hand.
