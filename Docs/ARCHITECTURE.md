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
│   ├── HotkeyMonitor.swift       [hotkey]  right-⌘ CGEventTap (press/release/cancel)
│   ├── MicrophoneCapture.swift   [audio]   AVAudioEngine → 16 kHz mono Float samples
│   ├── SoundFeedback.swift       [audio]   start/success/error sounds + haptics
│   ├── TextInserter.swift        [insert]  clipboard + synthetic ⌘V, restore, secure-input
│   ├── HistoryStore.swift        [menubar] recent transcriptions (in-memory)
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

protocol TranscriptionEngine: Actor {
    nonisolated var id: String { get }
    nonisolated var displayName: String { get }
    /// Downloads (if needed) and loads the model. Reports progress on arbitrary threads.
    func prepare(progress: @escaping @Sendable (ModelDownloadProgress) -> Void) async throws
    var isReady: Bool { get async }
    /// languageHint: BCP-47-ish code like "en" / "fr", nil = automatic.
    func transcribe(_ samples: [Float], languageHint: String?) async throws -> TranscriptionResult
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

### HotkeyMonitor [hotkey] — `HotkeyMonitor.swift`

```swift
@MainActor final class HotkeyMonitor {
    enum Mode: String, CaseIterable { case pushToTalk, toggle, hybrid }
    var mode: Mode                       // set by controller from settings
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
- Right ⌘: `.flagsChanged` with `keyboardEventKeycode == 54`; pressed iff
  `event.flags.rawValue & 0x10 != 0` (NX_DEVICERCMDKEYMASK — do NOT use `.maskCommand`,
  it stays set while the *left* ⌘ is held).
- **Never** swallow `flagsChanged` (would break right-⌘ combos). The ONLY event ever swallowed:
  `keyDown` keyCode 53 (Esc) while `setRecordingActive(true)` → `onCancel` + return nil.
- Combo guard: a non-modifier `keyDown` within 1.0 s of right-⌘ press while held → `onCancel`
  (the user was typing ⌘C etc.), do not swallow it.
- Hybrid mode: press → `onBegin`. Release after ≥ 0.5 s → `onEnd` (push-to-talk). Release
  < 0.5 s → keep recording hands-free; next right-⌘ press → `onEnd` (toggle).
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
  UserDefaults: `hotkeyMode`, `playSounds`, `hapticFeedback`, `restoreClipboard`,
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
  `activate()` (start hotkey + prepare engine), `deactivate()`,
  `prepareEngine(force: Bool = false)` (force re-runs even when `.ready` — Settings
  Re-download), `setDictationEnabled(_:)`, `startDictation() -> Bool` (false when the begin
  is declined so the hotkey monitor never opens a phantom session),
  `stopDictationAndTranscribe()`, `cancelDictation()`. Transcription runs under a timeout
  (`max(30 s, 4×audio + 5 s)`) so a wedged engine can never leave the app stuck in
  `.transcribing`.

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
