# MoDict

**Hold right ⌘. Speak. Your words appear wherever your cursor is — 100% on-device.**

MoDict is a quiet, local dictation tool for macOS. Press and hold the right Command
key, say something, let go, and the text is typed into whatever app is focused — your
editor, your browser, a chat box, a terminal. Transcription runs on the Apple Neural
Engine. No cloud, no account, no telemetry. An open-source alternative to Wispr Flow and
superwhisper, built to disappear until you need it.

[![CI](https://github.com/Tutanka01/MoDict/actions/workflows/build.yml/badge.svg)](https://github.com/Tutanka01/MoDict/actions/workflows/build.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-555.svg)](LICENSE)
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

### From Releases

1. Download `MoDict.app` from the [latest release](https://github.com/Tutanka01/MoDict/releases).
2. Move it to `/Applications`.
3. The build is not notarized, so macOS quarantines it. Clear the flag once:

   ```sh
   xattr -dr com.apple.quarantine /Applications/MoDict.app
   ```

4. Launch it. Onboarding walks you through permissions and the model download.

### Build from source

Command Line Tools are enough — you do **not** need Xcode.

```sh
xcode-select --install          # if you don't already have the CLT
git clone https://github.com/Tutanka01/MoDict.git
cd MoDict
make            # builds a universal .app into build/
make run        # builds and launches it
```

The first launch asks for the three permissions described below. If you plan to rebuild
often, sign with a stable certificate so the permissions persist across builds — see
[CONTRIBUTING.md](CONTRIBUTING.md#stable-signing-for-permissions).

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

## Licenses & attribution

MoDict is free software and builds on the work of others. Attribution is required.

| Component | License |
|---|---|
| MoDict | [MIT](LICENSE) |
| [FluidAudio](https://github.com/FluidInference/FluidAudio) | Apache-2.0 |
| [Parakeet-TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) model weights | CC-BY-4.0 — © NVIDIA |

The Parakeet-TDT 0.6B v3 weights are distributed by NVIDIA under
[CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/); using them requires crediting
NVIDIA, which this project does here and in Settings → About.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for setup, code style, file ownership, and how to
test the full dictation pipeline by hand.
