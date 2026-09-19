# MoDict

**Hold right ⌘. Speak. Your words appear wherever your cursor is.**

MoDict is a quiet, local dictation tool for macOS. Press and hold the right Command
key, say something, let go, and the text is typed into whatever app is focused — your
editor, your browser, a chat box, a terminal. Transcription runs locally on Apple Silicon
by default; optional OpenRouter models use the cloud. No telemetry. An open-source alternative to Wispr Flow and
superwhisper, built to disappear until you need it.

[![CI](https://github.com/Tutanka01/MoDict/actions/workflows/build.yml/badge.svg)](https://github.com/Tutanka01/MoDict/actions/workflows/build.yml)
[![Release](https://img.shields.io/github/v/release/Tutanka01/MoDict?color=555)](https://github.com/Tutanka01/MoDict/releases/latest)
[![License: AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-555.svg)](LICENSE)
[![Platform: macOS 15+](https://img.shields.io/badge/platform-macOS%2015%2B%20·%20Apple%20Silicon-555.svg)](#requirements)

## Why MoDict

- **Private by default.** The local models transcribe on your Mac. Selecting a cloud
  model sends each finished recording to OpenRouter and its model provider.
- **French-first by default.** New installations use Qwen3-ASR 1.7B locally through
  MLX for stronger multilingual and French transcription. Parakeet v3 remains available
  as a smaller, faster Neural Engine model with live preview.
- **Choose your model.** Manage Qwen3-ASR and Parakeet locally, or select one of three
  optional OpenRouter transcription models in Settings → Model.
- **It stays out of the way.** A small three-line composition preview appears near your
  pointer and vanishes the instant the text lands. No dashboard, no Dock icon —
  just a menu bar glyph.

## Requirements

- macOS 15 (Sequoia) or later
- Apple Silicon
- ~2.3 GB of disk for the default Qwen3-ASR model (~482 MB for Parakeet)

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
4. Launch MoDict. Onboarding walks you through permissions and model setup.

### Option 2 — Build from source

Building requires **Xcode 16 or later**: SwiftUI's `@State` and `@Observable` macros are
only distributed in the full Xcode toolchain, not in the Command Line Tools.

```sh
xcode-select -s /Applications/Xcode.app/Contents/Developer   # once, if needed
git clone https://github.com/Tutanka01/MoDict.git
cd MoDict
make            # builds, bundles, and signs build/MoDict.app
make run        # builds and launches it
make verify-bundle   # optional: prove the bundle is self-contained
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
rm -rf ~/Library/Application\ Support/MoDict       # downloaded Qwen models
defaults delete com.modict.app                     # settings
```

If you saved an OpenRouter key, remove it in Settings → Model before uninstalling,
or delete the "MoDict OpenRouter API key" item in Keychain Access afterward. The
Keychain item intentionally survives app deletion and restart.

## First launch

MoDict asks for three system permissions. Each one maps to a single, visible job:

- **Microphone** — to record your speech. Local models process audio on-device;
  a selected cloud model sends it to OpenRouter after you release the key.
- **Input Monitoring** — to notice when you press and release the right ⌘ key. MoDict
  watches for that one key; it does not read or store what you type.
- **Accessibility** — to paste the finished text into the app you're using, via a
  synthetic ⌘V at your cursor.

To be plain about what MoDict does **not** do: it is not a keylogger — the key monitor
only tracks the right ⌘ (and swallows Esc while you're recording, so you can cancel).
With local models, normal dictation makes no network request; downloading a local
model connects to Hugging Face. Cloud dictation requires an OpenRouter API key.

## Optional cloud transcription

In Settings → Model, choose **MAI-Transcribe 2** (`microsoft/mai-transcribe-2`),
**Muse Voice Transcribe 1.0** (`meta/muse-voice-transcribe-1.0`), or
**GPT Transcribe** (`openai/gpt-transcribe`). MoDict asks you to confirm the cloud
switch. Paste your [OpenRouter API key](https://openrouter.ai/settings/keys) into the
secure field and save it. The key is stored in this Mac's Keychain, survives app
restarts, and is never placed in UserDefaults. You can replace or remove it at any
time. A change of app signing identity may trigger a macOS Keychain access prompt.
An invalid key is reported on the first transcription.

Cloud dictation uploads the finished recording over HTTPS to OpenRouter, which routes
it to a model provider. Providers may retain audio or use it to improve models,
depending on their policies; [review OpenRouter's privacy policy](https://openrouter.ai/privacy/)
and your account privacy settings before using it with sensitive speech. Usage can
incur charges. Cloud recordings are limited to 10 minutes. Cloud models have no live
transcript preview. Switching back to Qwen3-ASR or Parakeet keeps subsequent audio
local.

## Usage

Three activation styles (set in Settings → General; **Hold to talk** is the default):

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
- **The model download stalls.** It comes from Hugging Face. Use Settings → Model →
  Download after checking your connection.

## How it works

1. A `CGEventTap` watches the right ⌘ key and starts capturing 16 kHz mono audio through
   `AVAudioEngine`.
2. While you speak, the HUD follows recording; Parakeet also shows a rolling text preview.
3. On release, the selected model transcribes the full clip once. A cloud model
   sends the recording to OpenRouter only at this point.
4. The text is placed on the pasteboard, pasted with a synthetic ⌘V at your cursor, and
   your previous clipboard is restored.

The state machine, module boundaries, and the pitfalls behind each of these steps are
documented in [Docs/ARCHITECTURE.md](Docs/ARCHITECTURE.md).

## Privacy

- With a local model selected, dictation audio stays on your Mac. With a cloud model
  selected, each finished recording is sent to OpenRouter and a model provider.
- No telemetry, analytics, or background phone-home. Cloud use requires an OpenRouter account.
- Local model downloads use Hugging Face. Cloud requests use OpenRouter only when you
  dictate with a cloud model selected.
- The OpenRouter key is stored in the macOS login Keychain, never in preferences
  or logs. Audio requests use an ephemeral URL session without a disk cache.
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
| [speech-swift](https://github.com/soniqo/speech-swift) | Apache-2.0 |
| [MLX](https://github.com/ml-explore/mlx) (runtime and Metal kernels) | MIT |
| [Qwen3-ASR 1.7B](https://huggingface.co/aufklarer/Qwen3-ASR-1.7B-MLX-4bit) model weights | Apache-2.0 |

The Parakeet-TDT 0.6B v3 weights are distributed by NVIDIA under
[CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/); using them requires crediting
NVIDIA, which this project does here and in Settings → About.

## Credits

MoDict is created and maintained by **Mohamad El Akhal**.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for setup, code style, file ownership, and how to
test the full dictation pipeline by hand.
