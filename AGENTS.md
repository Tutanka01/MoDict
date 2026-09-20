# MoDict — repository instructions

## Project and references

- macOS 15+, Apple Silicon; SwiftPM with the full Xcode toolchain (16+), no `.xcodeproj`.
  App code uses Swift language mode 5; tests use mode 6 and Swift Testing.
- Menu bar dictation: Qwen3-ASR is the local default; Parakeet supports live previews;
  OpenRouter models are opt-in cloud transcription. No telemetry.
- `Package.swift` is authoritative for platform, language modes and the three direct,
  exactly pinned dependencies (FluidAudio, speech-swift, mlx-swift). Inspect checked-out
  dependency APIs before changing integration code; don't upgrade pins incidentally.
- Read the relevant parts of `Docs/ARCHITECTURE.md`, `Docs/DESIGN.md` and
  `Docs/research/` before changing a module. `Docs/QA.md` covers manual release QA.
- Historical owner labels identify module boundaries, not permission barriers. A user
  request spanning modules authorizes the necessary edits. Preserve public contracts
  where possible; update callers and architecture docs together when they must change.
  Follow these instructions over obsolete machine-specific claims in older docs.

## Efficient development loop

Start with `git status --short`; preserve unrelated changes. Use `rg` to find callers
and existing helpers before writing code. Fix shared causes, reuse native APIs, and
keep the diff focused. Do not add abstractions or dependencies for hypothetical needs.

Run SwiftPM operations sequentially: never overlap `swift build`, `swift test`, or
Make targets that invoke them against the same `.build` directory. Keep incremental
builds; use `make clean` only to resolve a diagnosed build-cache problem.

| Need | Command |
| --- | --- |
| Check toolchain when setup is uncertain | `xcode-select -p` and `swift --version` |
| Compile without packaging | `swift build` |
| Run a relevant test suite (example) | `swift test --filter InterfaceStateTests` |
| Run all tests | `swift test` |
| Build release, bundle, sign and verify once | `make sign verify-bundle` |
| Recheck an existing bundle without rebuilding | `make verify-bundle` |
| Inspect signing | `make diagnose-signature` |
| Launch an already verified bundle directly | `build/MoDict.app/Contents/MacOS/MoDict` |
| Build and launch during development | `make run` |

- Xcode is installed on the current development machine; local tests can run. Check
  actual runner output and report executed tests, never compilation as a passing suite.
  `make test` can fall back to compile-only when the xctest host is unavailable.
- For logic changes, add the smallest meaningful regression check to the existing
  tests. Run relevant tests first; run the full suite for broad changes and before
  installing a changed build. Don't repeat passing checks without new changes or evidence.
- For UI changes, inspect light/dark rendering and the affected interaction. For
  dictation changes, exercise the relevant manual paths in `CONTRIBUTING.md`/`Docs/QA.md`;
  report what was actually checked. A launch check is not a microphone/insertion test.
- `make sign` already builds and bundles. Don't precede it with a redundant release
  build or follow it with `make run` just to launch. Avoid `make -j` for sign/verification;
  these goals must complete in order. Use `make universal` only when that artifact is needed.

## Invariants and installation

- `DictationController` alone owns dictation state and recovery. Preserve stale-result
  rejection, cancellation, timeouts and terminal HUD cleanup. Live preview is optional;
  final transcription comes from the full recorded utterance.
- UI/controller work stays on `@MainActor`; engines are actors. Audio callbacks must
  not access UI; event-tap callbacks must stay short and dispatch work to the main queue.
- Keep UI copy English, calm and concise, with the native minimal visual system and
  accessibility labels/keyboard operation. Preserve author credit and AGPL attribution.
- Preserve clipboard restoration, secure-field handling and in-memory-only history.
  Never log API keys, audio or transcripts; cloud selection must retain explicit consent.
- Local builds use the existing `MoDict Dev` signing identity and bundle ID
  `com.modict.app` so TCC permissions persist. Never silently switch to ad-hoc signing,
  recreate a working certificate, or reset TCC to work around a build problem.
- The Makefile embeds MLX kernels and any required framework/rpath. Keep the
  `disable-library-validation` entitlement and run `make verify-bundle` after signing;
  it checks the packaged app and executes real MLX kernels.
- An app update replaces only the `.app` bundle after validation. Quit the old process,
  preserve a recoverable old bundle until the replacement launches, and avoid running
  multiple copies. Preserve Application Support, downloaded models, preferences,
  vocabulary, usage records, API keys and permissions. The destructive QA reset commands
  are for an explicitly requested reset on a dedicated test environment.
- Version comes from `Makefile`; `Support/Info.plist.in` is its template. Installing a
  local build does not require a version bump, tag, push, notarization or GitHub release.
  Publish/tag only when explicitly requested; follow `.github/workflows/release.yml`
  and update `RELEASES.md` for an authorized release.
