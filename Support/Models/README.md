# Vendored models

`silero-vad-unified-256ms-v6.2.1.mlmodelc` is Silero VAD v6.2.1 (MIT, © Silero Team) as
converted to Core ML by FluidInference: `FluidInference/silero-vad-coreml` on Hugging Face,
commit `b419383c55c110e2c9271fa6ee0ea83d03c70d96`, MIT.

It ships inside the app, copied to `Contents/Resources` by `make bundle`, because normal
dictation with a local model makes no network request (README, Docs/QA.md) and because
FluidAudio's own download follows `resolve/main`, with no pinned revision.

To update: replace the folder from a new commit, update this file, rerun
`swift test --filter SpeechGateModelTests`, and rerun the no-speech and real-speech checks
in `Docs/research/transcription-benchmark.md`.
