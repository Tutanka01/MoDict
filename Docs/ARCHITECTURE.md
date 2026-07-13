# MoDict — Architecture

Local, push-to-talk dictation for macOS. Hold right ⌘ → record → release → Parakeet v3
transcribes on the Neural Engine → text is inserted at the cursor of whatever app is focused.

- Target: macOS 14+, Apple Silicon. Swift 6 toolchain, **language mode v5** (see Concurrency).
- Build: pure SwiftPM + Command Line Tools (no Xcode). `make` assembles the `.app` bundle.
- STT: [FluidAudio](https://github.com/FluidInference/FluidAudio) `exact: 0.15.5`,
  Parakeet-TDT 0.6B **v3** (multilingual, ~482 MB download, ANE).
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
│   ├── Permissions.swift         [core]    mic / accessibility / input-monitoring helpers
│   ├── HotkeyMonitor.swift       [hotkey]  configurable-key CGEventTap (press/release/cancel)
│   ├── MicrophoneCapture.swift   [audio]   AVAudioEngine → 16 kHz mono Float samples
│   ├── SoundFeedback.swift       [audio]   start/success/error sounds + haptics
│   ├── TextInserter.swift        [insert]  clipboard + synthetic ⌘V, restore, secure-input
│   ├── HistoryStore.swift        [menubar] recent transcriptions (in-memory)
│   ├── VocabularyStore.swift     [vocabulary] user text replacements (UserDefaults JSON)
│   └── Transcription/
│       ├── TranscriptionEngine.swift [stt] protocol + shared result/progress types
│       └── FluidAudioEngine.swift    [stt] FluidAudio/Parakeet implementation
└── UI/
    ├── Theme.swift               [core]    design tokens (see Docs/DESIGN.md)
    ├── HUD/
    │   ├── HUDController.swift   [hud]     show/hide/update the floating panel
    │   ├── HUDPanel.swift        [hud]     non-activating NSPanel subclass
    │   └── HUDView.swift         [hud]     SwiftUI capsule: waveform / dots / check / error
    ├── MenuBar/
    │   └── MenuBarView.swift     [menubar] popover content (status, history, footer)
    ├── Onboarding/
    │   ├── OnboardingController.swift [onboarding] window lifecycle
    │   └── OnboardingView.swift       [onboarding] 5 steps (see DESIGN.md)
    └── Settings/
        └── SettingsView.swift    [settings] tabs: General / Dictation / Model / About
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
struct TranscriptionResult: Sendable {
    let text: String
    let confidence: Float          // 0…1
    let audioDuration: TimeInterval
    let processingTime: TimeInterval
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
    /// languageHint: BCP-47-ish code like "en" / "fr", nil = automatic.
    func transcribe(_ samples: [Float], languageHint: String?) async throws -> TranscriptionResult
    /// Begin a streaming session (nil = engine can't stream at all). Synchronous
    /// so the session buffers audio from the first mic chunk; the recognizer
    /// spins up in the background and any failure degrades to no partials.
    /// `onPartial` fires on arbitrary threads. A new session cancels the previous
    /// one. Streaming always auto-detects language — only batch honors a pin.
    nonisolated func startStreamingSession(
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

Implementation notes (validated against FluidAudio 0.15.5 source — README snippets are WRONG):
- `AsrModels.downloadAndLoad(version: .v3, progressHandler:)` → `AsrManager(config: .default)`,
  `try await asr.loadModels(models)`.
- `transcribe`: create a **fresh** `TdtDecoderState` per utterance
  (`try TdtDecoderState()`), call
  `asr.transcribe(samples, decoderState: &state, language: mapped)`.
- Map `languageHint` string → FluidAudio's language type; check the real API in the checked-out
  sources (`.build/checkouts/FluidAudio/Sources/FluidAudio/...`) before writing code.
- Pad clips shorter than ~1 s with trailing silence (16 000 zero samples) before transcribing.
- Do not let two `prepare()` calls download twice (share the in-flight Task).
- Streaming: `prepare` retains the loaded `AsrModels`; each session gets a **fresh**
  `SlidingWindowAsrManager` sharing them (`loadModels(_:)` is reference assignment only) —
  the manager's input `AsyncStream` is built once in its `init` and permanently finished by
  `finish()`/`cancel()`, so an instance can never stream a second utterance (`reset()` does
  not revive it). Cadence knob is `chunkSeconds` (the presets' `hypothesisChunkSeconds` is
  never read in 0.15.5); MoDict uses left 10 + chunk 1 + right 1 = 12 s ≤ the model's 15 s
  input. Chunk ordering: tap thread → session-local `AsyncStream` (sync yield) → one pump
  task → actor-isolated `streamAudio`. Never a `Task {}` per chunk (unordered).
- After load, before reporting ready, run one throwaway transcription of 1 s of silence to
  pay CoreML's one-time ANE placement cost off the user's first dictation. The bar stays at
  compiling/0.99 during it; a warm-up failure is logged (`NSLog`) and never fails `prepare`.

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
    }
    @Published private(set) var items: [Item]   // newest first, max 5
    func add(_ text: String)
    func copyToClipboard(_ item: Item)
    func clear()
}
```
In-memory only (privacy) — no disk persistence.

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
    /// Live transcript beside the waveform (recording) / dots (transcribing);
    /// nil clears it. ~1/s, so it goes through the observable model (unlike
    /// `setLevel`); the capsule's width springs up to Theme.hudPartialMaxWidth,
    /// showing the tail of the text (leading truncation), confirmed in primary,
    /// volatile in secondary.
    func setPartial(_ partial: PartialTranscript?)
    func hide()                    // animate out, then orderOut
}
```
Panel: `NSPanel` subclass, `styleMask [.nonactivatingPanel, .fullSizeContentView]`,
`canBecomeKey/Main = false`, `level = .statusBar`, `collectionBehavior =
[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`, `isFloatingPanel`,
`hidesOnDeactivate = false`, clear/transparent, `ignoresMouseEvents = true`,
`NSHostingView` content. Position per `settings.hudPosition` on the screen containing the
mouse pointer. All visuals per Docs/DESIGN.md.

### Onboarding [onboarding] — `OnboardingController.swift`

```swift
@MainActor final class OnboardingController {
    init(app: AppModel)
    static func isNeeded(settings: SettingsStore) -> Bool
    // true if !settings.onboardingCompleted || !FluidAudioEngine.modelsExistOnDisk()
    func present()   // activates app (.regular policy), shows window, restores .accessory on close
}
```
The view drives real actions: `Permissions.*`, `app.controller.prepareEngine()`, and the
"Try it" step observes `app.controller.phase`/insertions to auto-advance. On finish it sets
`settings.onboardingCompleted = true` and calls `app.controller.activate()`.

## Core pieces (owner: core — already written, read them before implementing)

- `SettingsStore`: `@MainActor ObservableObject`, `@Published` properties persisted to
  UserDefaults: `hotkeyMode`, `dictationKey` (`DictationKey`, default `.rightCommand`),
  `playSounds`, `hapticFeedback`, `restoreClipboard`,
  `languageHint` ("auto"), `inputDeviceUID` (""), `hudPosition` (.bottomCenter/.topCenter),
  `keepMicWarm`, `launchAtLogin`, `onboardingCompleted`, `dictationEnabled`.
- `Permissions`: static helpers — `microphoneGranted`, `requestMicrophone() async -> Bool`,
  `accessibilityGranted`, `requestAccessibility()`, `inputMonitoringGranted`,
  `requestInputMonitoring()`, `openSettings(pane:)` deep-links.
- `AppModel`: `@MainActor` singleton (`AppModel.shared`) owning `settings`, `history`,
  `controller`. `MoDictApp`/`AppDelegate` bootstrap: onboarding if needed, else
  `controller.activate()`.
- `DictationController`: the only place that mutates dictation state. Public:
  `phase: Phase { idle, recording, transcribing }` (`@Published`),
  `modelState: ModelState { unknown, needsDownload, downloading(ModelDownloadProgress), ready,
  failed(String) }` (`@Published`), `userIssue: UserIssue?` (`@Published`, last actionable
  problem for the menu bar/HUD), `lastInsertedText: String?`,
  `partialTranscript: PartialTranscript?` (`@Published`, live transcript of the dictation in
  flight, vocabulary applied, nil whenever none is running),
  `activate()` (start hotkey + prepare engine), `deactivate()`,
  `prepareEngine(force: Bool = false)` (force re-runs even when `.ready` — Settings
  Re-download), `setDictationEnabled(_:)`, `startDictation() -> Bool` (false when the begin
  is declined so the hotkey monitor never opens a phantom session),
  `stopDictationAndTranscribe()`, `cancelDictation()`. Transcription runs under a timeout
  (`max(30 s, 4×audio + 5 s)`) so a wedged engine can never leave the app stuck in
  `.transcribing`.
  Streaming: `startDictation` also opens a best-effort streaming session (mic `onChunk` →
  session; partials hop to the main actor, drop when the recordingID is stale, get vocabulary
  applied, and land in `partialTranscript` + `hud.setPartial`). The final text is dual-path:
  language "auto" → `session.finish()` (near-zero latency; any throw / suspiciously empty
  result falls back to batch); pinned language → session cancelled, batch only (the sliding
  window API can't pin, so partials may differ slightly from the final). Every terminal path
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
