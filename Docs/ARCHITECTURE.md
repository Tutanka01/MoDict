# MoDict — Architecture

Push-to-talk dictation for macOS. Hold right ⌘ → record → release → the selected
local or OpenRouter model transcribes → text is inserted at the cursor of whatever app is focused.

- Target: macOS 15+, Apple Silicon. Swift 6 toolchain, **language mode v5** (see Concurrency).
- Build: SwiftPM + Xcode 16+ toolchain (SwiftUI macros; MLX ships prebuilt).
  `make` assembles the `.app` bundle, embeds `Cmlx.framework` and the
  `disable-library-validation` entitlement, and `make verify-bundle` proves the
  result launches.
- STT: Qwen3-ASR 1.7B 4-bit through speech-swift/MLX (new-install default), or
  FluidAudio 0.15.7 with Parakeet-TDT 0.6B v3 (smaller, ANE, live preview), or
  one of three opt-in OpenRouter speech models (batch only).
- No sandbox (CGEvent posting + global key monitoring are incompatible with it).

## Module map & file ownership

Every file has exactly one owner. Do not edit files you don't own. Public API of each module
is FROZEN as specified below — implement it exactly; add `private` helpers freely.

```
Sources/MoDict/
├── App/
│   └── MoDictApp.swift          [core]     @main, MenuBarExtra, Settings scene, AppDelegate
├── Core/
│   ├── DictationController.swift [core]    central state machine — owns all modules
│   ├── SettingsStore.swift       [core]    user preferences (UserDefaults-backed)
│   ├── OpenRouterKeyStore.swift  [core]    OpenRouter API key in a 0600 file
│   ├── Permissions.swift         [core]    mic / accessibility / input-monitoring helpers
│   ├── HotkeyMonitor.swift       [hotkey]  configurable-key CGEventTap (press/release/cancel)
│   ├── MicrophoneCapture.swift   [audio]   AVAudioEngine → 16 kHz mono Float samples
│   ├── SoundFeedback.swift       [audio]   start/success/error sounds + haptics
│   ├── TextInserter.swift        [insert]  clipboard + synthetic ⌘V, restore, secure-input
│   ├── HistoryStore.swift        [menubar] recent transcriptions (in-memory)
│   ├── VocabularyStore.swift     [vocabulary] user text replacements (UserDefaults JSON)
│   ├── UsageLedger.swift         [usage]   JSONL cost/usage ledger + aggregates + USD format
│   ├── UsageStore.swift          [usage]   main-actor façade publishing UsageSnapshot
│   └── Transcription/
│       ├── TranscriptionEngine.swift [stt] protocol + shared result/progress types
│       ├── FluidAudioEngine.swift    [stt] FluidAudio/Parakeet implementation
│       ├── QwenAudioEngine.swift     [stt] speech-swift/Qwen3-ASR implementation
│       └── OpenRouterEngine.swift    [stt] HTTPS batch transcription, in-memory WAV
└── UI/
    ├── Theme.swift               [core]    design tokens (see Docs/DESIGN.md)
    ├── Mark.swift                          the mark: app glyph + menu bar template images
    ├── HUD/
    │   ├── HUDController.swift   [hud]     show/hide/update the floating panel, placement
    │   ├── HUDPanel.swift        [hud]     non-activating NSPanel subclass
    │   ├── HUDView.swift         [hud]     SwiftUI model, smoked-glass capsule/card morph, states
    │   ├── HUDVoicePrint.swift   [hud]     the living mark: voice waveform + blinking cursor
    │   ├── HUDCaption.swift      [hud]     preview ink stamps + TextRenderer (entrance, caret, sweep)
    │   └── TextCaretLocator.swift [hud]    read-only AX lookup of the text cursor
    ├── MenuBar/
    │   └── MenuBarView.swift     [menubar] popover content (status, history, usage, footer)
    ├── Onboarding/
    │   ├── OnboardingController.swift [onboarding] window lifecycle
    │   └── OnboardingView.swift       [onboarding] 5 steps (see DESIGN.md)
    └── Settings/
        └── SettingsView.swift    [settings] sidebar: General / Dictation / Vocabulary / Model / Appearance / Usage / About
```

Root-level (owner **packaging**): `Makefile`, `Support/Info.plist.in`,
`Support/MoDict.entitlements`, `Support/generate-icon.swift`, `scripts/dev-cert.sh`,
`.github/workflows/build.yml`. Owner **docs**: `README.md`, `CONTRIBUTING.md`.

## The state machine (DictationController)

```
                 ┌────────────────────────────────────────────┐
                 ▼                                            │
   idle ── hotkey begin ──▶ recording ── hotkey end ──▶ transcribing ──▶ insert ──▶ idle
    ▲                          │                             │
    │        Esc / combo-cancel│               empty / error │
    └──────────────────────────┴─────────────────────────────┘
```

Robustness rules (all implemented in `DictationController`, don't duplicate):
- Each recording gets a `UUID`; async completions compare it and drop stale results.
- Recordings shorter than 0.35 s are cancelled silently (accidental taps).
- Empty transcription → transient "Didn't catch that." HUD, nothing inserted.
- The HUD must appear on key-down and always disappear — every code path ends with
  `hud.hide()` or a transient state that schedules it.

## Frozen public contracts

### Types shared by everyone (declared in `TranscriptionEngine.swift` [stt])

```swift
/// Billing metadata a cloud provider reported for one request (nil locally).
struct TranscriptionUsage: Sendable, Equatable {
    let audioSeconds: Double?
    let inputTokens: Int?
    let outputTokens: Int?
    let costUSD: Decimal?          // exact amount charged for this request
}

struct TranscriptionResult: Sendable {
    let text: String
    let confidence: Float          // 0…1
    let audioDuration: TimeInterval
    let processingTime: TimeInterval
    let usage: TranscriptionUsage? // cloud only
    // Explicit init with `usage` defaulted to nil keeps every existing call
    // site (engines, tests) source-compatible.
}

struct ModelDownloadProgress: Sendable, Equatable {
    enum Phase: Sendable, Equatable { case checking, downloading, compiling, ready }
    let phase: Phase
    let fraction: Double           // 0…1 overall
}

/// Incremental transcript of an in-flight streaming session.
struct PartialTranscript: Sendable, Equatable {
    let confirmedText: String      // stable
    let volatileText: String       // trailing hypothesis, may still be revised
    var isEmpty: Bool { get }
}

/// Handle to one live streaming transcription session (one utterance).
protocol StreamingTranscriptionSession: AnyObject, Sendable {
    /// Synchronous, non-blocking, audio-thread-safe; a single producer keeps
    /// chunk order. Chunks after finish()/cancel() are dropped.
    func feed(_ chunk: [Float])
    /// Drains everything fed and returns the final transcript. Throws when
    /// streaming never got off the ground — caller falls back to batch.
    func finish() async throws -> TranscriptionResult
    func cancel() async            // silent, idempotent
}

protocol TranscriptionEngine: Actor {
    nonisolated var id: String { get }
    nonisolated var displayName: String { get }
    /// Downloads (if needed) and loads the model. Reports progress on arbitrary threads.
    func prepare(progress: @escaping @Sendable (ModelDownloadProgress) -> Void) async throws
    var isReady: Bool { get async }
    /// languageHint: BCP-47-ish code like "en" / "fr", nil/"auto" = the Mac's
    /// language when the model supports it, otherwise model detection.
    func transcribe(_ samples: [Float], languageHint: String?) async throws -> TranscriptionResult
    /// Begin a streaming session (nil = engine can't stream at all). Synchronous
    /// so the session buffers audio from the first mic chunk; the recognizer
    /// spins up in the background and any failure degrades to no partials.
    /// `onPartial` fires on arbitrary threads. A new session cancels the previous
    /// one. `languageHint` pins the preview exactly like batch (since
    /// FluidAudio 0.15.6 the sliding-window path accepts a language).
    nonisolated func startStreamingSession(
        languageHint: String?,
        onPartial: @escaping @Sendable (PartialTranscript) -> Void
    ) -> StreamingTranscriptionSession?
    func unload() async
}
```

### FluidAudioEngine [stt] — `FluidAudioEngine.swift`

```swift
actor FluidAudioEngine: TranscriptionEngine {
    init()
    /// True if the v3 model files already exist on disk (cheap, for onboarding gating).
    static func modelsExistOnDisk() -> Bool
    /// Directory where models are stored (for "Reveal in Finder").
    static var modelsDirectory: URL { get }
    static let approximateDownloadBytes: Int64   // ~482 MB
    /// Languages Parakeet v3 supports, as (code, englishName) pairs, sorted by name.
    static let supportedLanguages: [(code: String, name: String)]
}
```

Implementation notes (validated against FluidAudio 0.15.7 source — README snippets are WRONG):
- `AsrModels.downloadAndLoad(version: .v3, progressHandler:)` →
  `AsrManager(config: ASRConfig(dualDecodeArbitration: true))`, `try await asr.loadModels(models)`.
  v3 long-form already resolves to the no-mel, silence-aligned path by default in 0.15.7
  (issue #594); the arbitration flag only affects utterances over 15 s.
- `transcribe`: condition the capture first (`AudioConditioner` trims to speech bounds and
  lifts quiet audio; never append digital silence — NVIDIA NeMo #15757), then create a
  **fresh** `TdtDecoderState` per utterance (`try TdtDecoderState()`) and call
  `asr.transcribe(audio, decoderState: &state, language: mapped)`. If a nonzero trim
  produced empty text, retry the untouched buffer once.
- Language mapping: `resolvedLanguageCode(for:preferredLanguages:)` — explicit hint wins;
  nil/empty/"auto" → the Mac's preferred language when Parakeet supports it, English and
  unsupported codes → nil (model detection). This is what activates the French
  English-blocklist; `language: nil` disables it entirely. Check the real API in the
  checked-out sources (`.build/checkouts/FluidAudio/Sources/FluidAudio/...`) before writing code.
- Do not let two `prepare()` calls download twice (share the in-flight Task).
- Streaming: `prepare` retains the loaded `AsrModels`; each session gets a **fresh**
  `SlidingWindowAsrManager` sharing them (`loadModels(_:)` is reference assignment only) —
  the manager's input `AsyncStream` is built once in its `init` and permanently finished by
  `finish()`/`cancel()`, so an instance can never stream a second utterance (`reset()` does
  not revive it). Cadence knob is `chunkSeconds` (the presets' `hypothesisChunkSeconds` is
  never read); MoDict uses left 10 + chunk 1 + right 1 = 12 s ≤ the model's 15 s
  input, with `config.language` pinned from the same hint as batch (0.15.6+). Chunk ordering:
  tap thread → session-local `AsyncStream` (sync yield) → one pump
  task → actor-isolated `streamAudio`. Never a `Task {}` per chunk (unordered).
- After load, before reporting ready, run one throwaway transcription of 1 s of silence to
  pay CoreML's one-time ANE placement cost off the user's first dictation. The bar stays at
  compiling/0.99 during it; a warm-up failure is logged (`NSLog`) and never fails `prepare`.

### SpeechModel [stt] — `TranscriptionEngine.swift`

```swift
/// The models exposed in Settings. Raw values are persisted in UserDefaults — stable.
enum SpeechModel: String, CaseIterable, Identifiable, Sendable {
    case qwen3ASR1_7B = "qwen3-asr-1.7b-4bit"   // fresh-install default
    case parakeetV3   = "parakeet-v3"           // keeps upgrading installs unchanged
    case maiTranscribe2 = "microsoft/mai-transcribe-2"
    case museVoiceTranscribe = "meta/muse-voice-transcribe-1.0"
    case gptTranscribe = "openai/gpt-transcribe"
    var isCloud: Bool
    var displayName / detail / attribution: String
    var approximateDownloadBytes: Int64
    var modelsDirectory: URL?              // nil for cloud models
    var isDownloaded: Bool
}
```

`SettingsStore.speechModel` resolves to `.parakeetV3` when `onboardingCompleted` is already
true (an upgrade must not silently pull ~2.3 GB) and to `.qwen3ASR1_7B` otherwise.

### QwenAudioEngine [stt] — `QwenAudioEngine.swift`

```swift
actor QwenAudioEngine: TranscriptionEngine {
    static let modelID = "aufklarer/Qwen3-ASR-1.7B-MLX-4bit"
    static var modelsDirectory: URL { get }     // ~/Library/Application Support/MoDict/Models/…
    static func modelsExistOnDisk() -> Bool
    static func deleteModels() throws
    static func language(for hint: String?) -> String?   // "fr-FR" → "fr"; "auto"/nil → nil
}
```

- `Qwen3ASRModel.fromPretrained(modelId:cacheDir:progressHandler:)` downloads the weights
  flat into `cacheDir` (config.json, vocab.json, `*.safetensors`, shard index) and skips
  files already present, so an interrupted download resumes on the next attempt.
  `modelsExist(at:)` requires `vocab.json` plus the weight file(s).
- Batch only: `startStreamingSession` returns nil. The live preview while Qwen is active comes
  from Parakeet running locally as the preview engine (see `DictationController`). Transcription applies the same `AudioConditioner` pass
  and raw-buffer retry as Parakeet, then `Qwen3DecodingOptions(language:repetitionPenalty:)`.
- The runtime is the MLX binary framework `Cmlx.framework`; `make bundle` embeds it and the
  matching rpath, and the `disable-library-validation` entitlement is mandatory. See
  `scripts/verify-bundle.sh`.

### HotkeyMonitor [hotkey] — `HotkeyMonitor.swift`

```swift
/// User-selectable trigger key. Each is a right-hand / secondary modifier read via
/// `.flagsChanged` with a device-specific flag bit (`flagMask`) keyed to its
/// `keyCode`, so release is detected even when the left-hand sibling is still held.
enum DictationKey: String, CaseIterable {
    case rightCommand   // keyCode 54, flagMask 0x10   (NX_DEVICERCMDKEYMASK)
    case rightOption    // keyCode 61, flagMask 0x40   (NX_DEVICERALTKEYMASK)
    case rightControl   // keyCode 62, flagMask 0x2000 (NX_DEVICERCTLKEYMASK)
    case globe          // keyCode 63, flagMask 0x800000 (NX_SECONDARYFNMASK / .maskSecondaryFn)
    var keyCode: Int64          // virtual keycode in .flagsChanged
    var flagMask: UInt64        // device-dependent bit set while held
    var displayName: String     // "Right Command" … "Globe (fn)"
    var shortName: String       // "Command" … "Globe" (compact picker label)
    var keycapSymbol: String    // SF Symbol name for the keycap ("command" … "globe")
    var holdHint: String        // "hold right ⌘" / "hold 🌐"
    var inlineName: String      // "right ⌘" / "Globe" (mid-sentence copy)
}

@MainActor final class HotkeyMonitor {
    enum Mode: String, CaseIterable { case pushToTalk, toggle, hybrid }
    var mode: Mode                       // set by controller from settings
    /// The trigger modifier, set by the controller from settings. Changing it while
    /// a session is live cancels that session (its release lives on the old key).
    var key: DictationKey                // default .rightCommand
    /// Start recording. Returns whether the controller actually accepted — the
    /// monitor only opens a session on `true`, so a declined begin (model not
    /// ready, mic missing, engine busy) can never leave a phantom hands-free
    /// session that would swallow the next key press.
    var onBegin: (() -> Bool)?
    var onEnd: (() -> Void)?             // stop + transcribe (main thread)
    var onCancel: (() -> Void)?          // combo interruption or Esc (main thread)
    var onPermissionLost: (() -> Void)?  // tap died and could not be re-armed
    /// Creates the CGEventTap. Returns false when Input Monitoring permission is missing.
    @discardableResult func start() -> Bool
    func stop()
    /// True while the tap considers a dictation session active (between begin and end/cancel).
    private(set) var isSessionActive: Bool
    /// Called by the controller so Esc-swallowing only happens while recording.
    func setRecordingActive(_ active: Bool)
}
```

Implementation (from research, see `ShortcutMonitor` pattern):
- `CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
  eventsOfInterest: flagsChanged|keyDown)`. Callback must be trivial — flip state, dispatch to main.
- Trigger key: `.flagsChanged` with `keyboardEventKeycode == key.keyCode`; pressed iff
  `event.flags.rawValue & key.flagMask != 0` (device-dependent bit — do NOT use
  `.maskCommand`/`.maskAlternate` etc., they stay set while the *left* sibling is held).
- **Never** swallow `flagsChanged` (would break the key's combos). The ONLY event ever swallowed:
  `keyDown` keyCode 53 (Esc) while `setRecordingActive(true)` → `onCancel` + return nil.
- Combo guard: a non-modifier `keyDown` within 1.0 s of the trigger press while held → `onCancel`
  (the user was typing ⌘C, or fn+arrow when the key is Globe), do not swallow it. The
  `modifierKeyCodes` 54…63 range covers all four trigger keycodes.
- Hybrid mode: press → `onBegin`. Release after ≥ 0.5 s → `onEnd` (push-to-talk). Release
  < 0.5 s → keep recording hands-free; next trigger press → `onEnd` (toggle).
- Cooldown 0.4 s between session starts. Use `ProcessInfo.processInfo.systemUptime` for timing.
- Re-arm on `.tapDisabledByTimeout` / `.tapDisabledByUserInput` (reset pressed state!) + a 5 s
  watchdog Timer checking `CGEvent.tapIsEnabled`.

### MicrophoneCapture [audio] — `MicrophoneCapture.swift`

```swift
final class MicrophoneCapture: @unchecked Sendable {
    struct InputDevice: Identifiable, Hashable, Sendable {
        var id: String { uid }
        let uid: String
        let name: String
    }
    enum CaptureError: Error { case noInputDevice, invalidFormat, engineStartFailed }
    /// Visible level 0…1, called on an arbitrary thread at buffer rate.
    var onLevel: (@Sendable (Float) -> Void)?
    /// Converted 16 kHz mono chunk, called on the audio thread at buffer rate —
    /// exactly the samples appended to the utterance (same generation guard as
    /// `onLevel`). Set once at wiring time; mutating it while the engine runs
    /// would race the tap thread.
    var onChunk: (@Sendable ([Float]) -> Void)?
    /// Start/stop once at launch to prime CoreAudio & surface the mic permission early.
    func warmUp()
    func start(deviceUID: String?) throws
    /// Stops and returns the full utterance as 16 kHz mono Float32 samples.
    func stop() -> [Float]
    /// Stops discarding audio.
    func cancel()
    static func availableInputDevices() -> [InputDevice]
}
```

Non-negotiable details (each one is a documented production bug — see Docs/research):
- Tap with the **native** input format; single reused `AVAudioConverter` to 16 kHz/1ch/Float32;
  input block returns `.haveData` once then **`.noDataNow`** — NEVER `.endOfStream`.
- Guard `kAudioHardwarePropertyDefaultInputDevice != kAudioDeviceUnknown` before touching
  `engine.inputNode` (ObjC exception otherwise).
- State behind `NSLock` + generation counter (straggler tap callbacks must not leak into the
  next utterance). Fresh `AVAudioEngine` instance after each stop.
- Observe `.AVAudioEngineConfigurationChange` → rebuild engine + converter (AirPods mid-session).
- Level mapping: RMS → dB → `(db+52)/20`, gate < 0.06, then `pow(x, 0.42)`.
- Device selection via `AudioUnitSetProperty(kAudioOutputUnitProperty_CurrentDevice)` before start.

### SoundFeedback [audio] — `SoundFeedback.swift`

```swift
@MainActor final class SoundFeedback {
    init(settings: SettingsStore)
    func dictationStarted()   // tick + haptic .alignment
    func dictationSucceeded() // pop + haptic .levelChange
    func dictationFailed()    // basso
}
```
System sounds by path (`/System/Library/Sounds/…`), preloaded, `volume ≈ 0.3`, gated on
`settings.playSounds` / `settings.hapticFeedback`.

### TextInserter [insert] — `TextInserter.swift`

```swift
enum InsertOutcome: Equatable, Sendable {
    enum FailureReason: Equatable, Sendable { case pasteboardWriteFailed, pasteShortcutFailed, cancelled }
    case inserted, secureInputBlocked, noAccessibilityPermission
    case failed(FailureReason)
}

@MainActor final class TextInserter {
    init(settings: SettingsStore)
    func insert(_ text: String) async -> InsertOutcome
}
```
Clipboard + synthetic ⌘V (virtualKey 0x37/0x09, `.maskCommand`, `.cghidEventTap`,
`CGEventSource(stateID: .privateState)`), 0.10 s pre-paste delay, 0.01 s between events.
Snapshot ALL `NSPasteboardItem`s; mark our write with a `com.modict.PasteSession` UUID type +
`org.nspasteboard.TransientType`/`AutoGeneratedType`; restore after ≥ 0.25 s **only if** the
pasteboard still holds our session (string matches AND marker matches). Check
`IsSecureEventInputEnabled()` (Carbon) first; check `AXIsProcessTrusted()`.
`settings.restoreClipboard` gates restoration.

### HistoryStore [menubar] — `HistoryStore.swift`

```swift
@MainActor final class HistoryStore: ObservableObject {
    struct Item: Identifiable, Equatable {
        let id: UUID
        let text: String
        let date: Date
        let costUSD: Decimal?      // what this dictation cost on a cloud model
    }
    @Published private(set) var items: [Item]   // newest first, max 5
    func add(_ text: String, costUSD: Decimal? = nil)
    func copyToClipboard(_ item: Item)
    func clear()
}
```
In-memory only (privacy) — no disk persistence. The per-dictation cost dies with the
item; the durable copy lives in `UsageLedger`.

### UsageLedger / UsageStore [usage] — `UsageLedger.swift`, `UsageStore.swift`

```swift
struct UsageRecord: Codable, Sendable, Equatable {
    var schemaVersion: Int
    var date: Date
    var day: String                // local "yyyy-MM-dd", frozen at write time
    var modelID: String            // SpeechModel.rawValue
    var isCloud: Bool
    var audioSeconds: Double
    var processingSeconds: Double
    var inputTokens: Int?
    var outputTokens: Int?
    var costUSD: Decimal?          // exact OpenRouter charge for this request
    // custom init(from:) using decodeIfPresent on every field: additive fields
    // must never break old lines.
}

struct UsageSnapshot: Sendable, Equatable {
    struct ModelUsage: Sendable, Equatable, Identifiable { /* count, audioSeconds, costUSD, unpricedCount */ }
    var totalCount, todayCount: Int
    var totalUSD, todayUSD: Decimal
    var unpricedCount: Int         // cloud 200s whose response carried no usage block
    var models: [ModelUsage]       // sorted by spend, then dictation count
    var isEmpty, hasSpend: Bool
}

actor UsageLedger {
    static var defaultFileURL: URL  // ~/Library/Application Support/MoDict/Usage/ledger.jsonl
    init(fileURL: URL = UsageLedger.defaultFileURL)
    func snapshot() -> UsageSnapshot
    @discardableResult func record(_ record: UsageRecord) -> UsageSnapshot
    func reset()
}

enum UsageFormat {
    /// Adaptive decimals: <$0.0001 · $0.0005 · $0.012 · $1.24; never "$0.00" for a positive cost.
    static func cost(_ value: Decimal, locale: Locale = .current) -> String
}

@MainActor final class UsageStore: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot
    init(ledger: UsageLedger = UsageLedger())
    func refresh() async          // load once, publish
    func record(_ record: UsageRecord) async
    func reset() async
}
```

Rules:
- One line per **finished** dictation, appended by `DictationController.finishTranscription`
  (the single landing point for every engine result) — including the empty-text and
  failed-paste paths, because a successful cloud response is billed regardless. Failures and
  timeouts write nothing (failed generations are not billed).
- `usage.cost` from the OpenRouter response is the source of truth; a response without a
  `usage` block still records the dictation and counts toward `unpricedCount`.
- Append + fsync per record (~1–2 ms measured); reads tolerate truncated/unknown lines;
  aggregates recompute in one pass. No database — see `Docs/research/usage-cost-tracking.md`
  for the volume thresholds that would justify SQLite, and why not GRDB/SwiftData.
- Metrics only — never transcript text. Directory 0o700, file 0o600.

### VocabularyStore [vocabulary] — `VocabularyStore.swift`

```swift
struct VocabularyRule: Identifiable, Codable, Equatable {
    let id: UUID
    var phrase: String        // what the engine heard
    var replacement: String   // what to insert instead
}

@MainActor final class VocabularyStore: ObservableObject {
    @Published var rules: [VocabularyRule]   // persisted as JSON to UserDefaults ("vocabularyRules")
    init(defaults: UserDefaults = .standard)
    /// Rewrites every transcription before insertion.
    func apply(to text: String) -> String
}
```

`apply(to:)` does one non-overlapping left-to-right pass. Rules are ordered longest
phrase first (ICU alternation is ordered, not longest-match) so the longest phrase wins
at a shared position; text a rule already wrote is never re-matched. Boundaries are
Unicode letter/number lookarounds `(?<![\p{L}\p{N}])…(?![\p{L}\p{N}])` (not `\b`, which
misbehaves around non-ASCII), the phrase is regex-escaped, internal whitespace becomes
`\s+`, case-insensitive. Casing: a replacement containing any uppercase is used verbatim;
an all-lowercase replacement adapts its first letter to the matched occurrence. An empty
replacement deletes the phrase, then doubled spaces are collapsed and the result trimmed.
Blank phrases are ignored. `DictationController.finishTranscription` calls it before the
empty-check, so an all-deleted result takes the "Didn't catch that." path.

### HUDController [hud] — `HUDController.swift`

```swift
enum HUDState: Equatable {
    case recording
    case transcribing
    case success
    case error(message: String, symbol: String)  // symbol = SF Symbol name
}

@MainActor final class HUDController {
    init(settings: SettingsStore)
    func show(_ state: HUDState)   // creates/orders the panel if needed, animates state change
    func setLevel(_ level: Float)  // 0…1 mic level, forwarded to the waveform
    /// Cumulative preview in the composition card; nil clears it. The card grows
    /// once (height only, away from the pinned screen edge), then a fixed
    /// three-line bottom-pinned viewport shows the tail under a constant top
    /// fade — no ScrollView, no per-partial animation.
    func setPartial(_ partial: PartialTranscript?)
    /// Release vs hands-free stop gesture. Shown only while the gesture is being
    /// learned (`settings.gestureHintsRemaining > 0`), unless `persistent`.
    func setActionHint(_ hint: String, persistent: Bool = false)
    func setSilenceWarning(_ warning: Bool)  // silence watchdog
    var caretLocator: () -> NSRect?          // injectable; defaults to TextCaretLocator
    /// Pure placement geometry (unit-tested): panel origin + pinned card edges.
    static func layout(position:anchor:visible:safeTop:) -> (origin: NSPoint, placement: HUDPlacement)
    func hide()                    // animate out, then orderOut
}
```
Panel: `NSPanel` subclass, `styleMask [.nonactivatingPanel, .fullSizeContentView]`,
`canBecomeKey/Main = false`, `level = .statusBar`, `collectionBehavior =
[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`, `isFloatingPanel`,
`hidesOnDeactivate = false`, clear/transparent, `ignoresMouseEvents = true`,
`NSHostingView` content. Default position (`nearPointer`, shown as “At your cursor”) hangs
the card below the text cursor that `TextCaretLocator` reads on key-down (read-only AX,
40 ms messaging timeout, reusing the paste permission), falling back to the pointer captured
on key-down when the focused app reports no caret. The anchor is frozen for the session.
Legacy bottom/top positions remain selectable. Edge modes pin the card's near edge — top-center pins
the card top just below the menu bar (and below the camera housing via `safeAreaInsets` when
the menu bar auto-hides) and grows downward only; bottom-center mirrors it — so the growing
preview never crosses into the notch band. All visuals per Docs/DESIGN.md.

### Onboarding [onboarding] — `OnboardingController.swift`

```swift
@MainActor final class OnboardingController {
    init(app: AppModel)
    static func isNeeded(settings: SettingsStore) -> Bool
    // true if onboarding is incomplete or a selected local model is not downloaded
    func present()   // activates app (.regular policy), shows window, restores .accessory on close
}
```
The view drives real actions: `Permissions.*`, `app.controller.prepareEngine()`, and the
"Try it" step observes `app.controller.phase`/insertions to auto-advance. On finish it sets
`settings.onboardingCompleted = true` and calls `app.controller.activate()`.

## Core pieces (owner: core — already written, read them before implementing)

- `SettingsStore`: `@MainActor ObservableObject`, `@Published` properties persisted to
  UserDefaults: `hotkeyMode`, `dictationKey` (`DictationKey`, default `.rightCommand`),
  `playSounds`, `hapticFeedback`, `restoreClipboard`, `speechModel`,
  `languageHint` ("auto" = the Mac's language when supported, else model detection),
  `inputDeviceUID` (""), `hudPosition`
  (.nearPointer/.bottomCenter/.topCenter, near-pointer default + one-time migration),
  `keepMicWarm`, `launchAtLogin`, `onboardingCompleted`, `dictationEnabled`,
  `gestureHintsRemaining` (HUD guidance: 8 on a fresh install, 0 on upgrade, decremented by
  `recordGuidedDictation()` on each successful paste, reset when the key or mode changes).
- `Permissions`: static helpers — `microphoneGranted`, `requestMicrophone() async -> Bool`,
  `accessibilityGranted`, `requestAccessibility()`, `inputMonitoringGranted`,
  `requestInputMonitoring()`, `openSettings(pane:)` deep-links.
- `AppModel`: `@MainActor` singleton (`AppModel.shared`) owning `settings`, `history`,
  `vocabulary`, `usage`, `controller`. `MoDictApp`/`AppDelegate` bootstrap: onboarding if
  needed, else `controller.activate()`, then `usage.refresh()`.
- `DictationController`: the only place that mutates dictation state. Public:
  `phase: Phase { idle, recording, transcribing }` (`@Published`),
  `modelState: ModelState { unknown, needsDownload, needsAPIKey, downloading(ModelDownloadProgress), ready,
  failed(String) }` (`@Published`), `userIssue: UserIssue?` (`@Published`, last actionable
  problem for the menu bar/HUD), `lastInsertedText: String?`,
  `partialTranscript: PartialTranscript?` (`@Published`, live transcript of the dictation in
  flight, vocabulary applied, nil whenever none is running),
  `activate()` (start hotkey + prepare engine), `deactivate()`,
  `prepareEngine()` (download+load the selected model when it is not ready),
  `preparePreviewEngine()` (load Parakeet as the preview engine for models that don't stream,
  when `settings.livePreview` is on and its model is on disk; never downloads; unloads it
  otherwise),
  `downloadModel(_:)`, `selectModel(_:)`, `deleteModel(_:)`, `modelState(for:)`
  (per-model state for Settings), plus `modelStates`, `isManagingModel`, `setDictationEnabled(_:)`,
  `startDictation() -> Bool` (false when the begin
  is declined so the hotkey monitor never opens a phantom session),
  `stopDictationAndTranscribe()`, `cancelDictation()`. Transcription runs under a timeout
  (`max(30 s, 4×audio + 5 s)` locally, 75 s minimum for cloud) so a wedged engine
  cannot leave the app stuck in `.transcribing`.
  Streaming: `startDictation` opens a best-effort preview session on the preview engine (the
  selected engine when it streams, otherwise Parakeet when Live preview is on and downloaded;
  mic `onChunk` → session;
  `StreamingTranscriptAssembler` merges overlapping hypotheses into a cumulative document;
  updates hop to the main actor, drop when the recordingID is stale, get vocabulary applied,
  and land in `partialTranscript` + `hud.setPartial`). It is never authoritative. The session
  receives the same language hint as batch so the preview cannot drift into English.
  On stop, the session is cancelled and the full captured utterance is transcribed once through
  batch (which also honors a pinned language). `TranscriptSanitizer` then removes only adjacent
  duplicated spans of 5+ words before vocabulary and insertion. Every terminal path
  cancels the session and clears `partialTranscript`; a <0.35 s recording cancels it silently.
  The full-utterance sample buffer remains the batch input and fallback — streaming failures
  must never break dictation.

## Concurrency rules

- Language mode v5 (`.swiftLanguageMode(.v5)` in Package.swift): keep code *clean* for a later
  strict-mode migration but don't fight the checker.
- UI + controller: `@MainActor`. Audio tap callbacks: lock-protected, never touch UI directly.
- CGEventTap callback: flip primitive state, `DispatchQueue.main.async` out. Nothing slow, ever.
- Engine: actor. Level updates: `onLevel` (audio thread) → HUD via main-queue dispatch,
  throttled naturally by buffer rate.

## Research

`Docs/research/*.md` contains the full validated research (APIs, pitfalls, timings, sources)
per module. **Read your module's file before writing code.**
