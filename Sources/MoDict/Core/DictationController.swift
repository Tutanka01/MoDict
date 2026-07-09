import AppKit
import Foundation
import Carbon.HIToolbox

/// Application-wide services. `MoDictApp` and `AppDelegate` both need the same
/// instances, so they live behind a main-actor singleton.
@MainActor
final class AppModel {
    static let shared = AppModel()

    let settings: SettingsStore
    let history: HistoryStore
    let controller: DictationController

    private init() {
        let settings = SettingsStore()
        let history = HistoryStore()
        self.settings = settings
        self.history = history
        self.controller = DictationController(settings: settings, history: history)
    }
}

/// The one place that mutates dictation state. Owns every module and wires the
/// pipeline: hotkey → microphone → transcription → insertion, with the HUD and
/// sound feedback reflecting each step. See Docs/ARCHITECTURE.md for the state
/// machine and robustness rules.
@MainActor
final class DictationController: ObservableObject {

    enum Phase: Equatable {
        case idle
        case recording
        case transcribing
    }

    enum ModelState: Equatable {
        case unknown
        case needsDownload
        case downloading(ModelDownloadProgress)
        case ready
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var modelState: ModelState = .unknown
    @Published private(set) var lastInsertedText: String?

    let settings: SettingsStore
    let history: HistoryStore

    private let hotkey: HotkeyMonitor
    private let microphone: MicrophoneCapture
    private let engine: FluidAudioEngine
    private let inserter: TextInserter
    private let hud: HUDController
    private let sounds: SoundFeedback

    /// Identity of the recording in flight; async completions compare against it
    /// and drop themselves when stale (double-taps, rapid re-triggers).
    private var currentRecordingID: UUID?
    private var recordingStartedAt: TimeInterval = 0
    private var prepareTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?

    /// Recordings shorter than this are treated as accidental and dropped.
    private static let minimumUtteranceSeconds: TimeInterval = 0.35
    private static let sampleRate = 16_000

    init(settings: SettingsStore, history: HistoryStore) {
        self.settings = settings
        self.history = history
        self.hotkey = HotkeyMonitor()
        self.microphone = MicrophoneCapture()
        self.engine = FluidAudioEngine()
        self.inserter = TextInserter(settings: settings)
        self.hud = HUDController(settings: settings)
        self.sounds = SoundFeedback(settings: settings)

        hotkey.mode = settings.hotkeyMode
        hotkey.onBegin = { [weak self] in self?.startDictation() }
        hotkey.onEnd = { [weak self] in self?.stopDictationAndTranscribe() }
        hotkey.onCancel = { [weak self] in self?.cancelDictation() }

        microphone.onLevel = { [weak self] level in
            DispatchQueue.main.async {
                self?.hud.setLevel(level)
            }
        }
    }

    // MARK: Lifecycle

    /// Start listening for the hotkey and load the model. Safe to call repeatedly.
    func activate() {
        hotkey.mode = settings.hotkeyMode
        hotkey.start()
        microphone.warmUp()
        prepareEngine()
    }

    func deactivate() {
        cancelDictation()
        hotkey.stop()
    }

    func refreshHotkeyMode() {
        hotkey.mode = settings.hotkeyMode
    }

    /// Download (if needed) and load the Parakeet model, publishing progress.
    func prepareEngine() {
        guard prepareTask == nil, modelState != .ready else { return }
        modelState = FluidAudioEngine.modelsExistOnDisk()
            ? .downloading(ModelDownloadProgress(phase: .checking, fraction: 0))
            : .needsDownload
        prepareTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.engine.prepare { progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.modelState != .ready else { return }
                        self.modelState = .downloading(progress)
                    }
                }
                self.modelState = .ready
            } catch {
                self.modelState = .failed(error.localizedDescription)
            }
            self.prepareTask = nil
        }
    }

    // MARK: Dictation flow

    func startDictation() {
        guard settings.dictationEnabled, phase == .idle else { return }
        guard case .ready = modelState else {
            transientHUD(.error(message: "Model not ready yet", symbol: "arrow.down.circle"),
                         dwell: Theme.errorDwell)
            return
        }
        guard Permissions.microphoneGranted else {
            transientHUD(.error(message: "Microphone access needed", symbol: "mic.slash"),
                         dwell: Theme.errorDwell)
            return
        }

        let recordingID = UUID()
        currentRecordingID = recordingID
        recordingStartedAt = ProcessInfo.processInfo.systemUptime

        // HUD first: it must be on screen at key-down, before audio flows.
        hideTask?.cancel()
        hud.show(.recording)
        do {
            try microphone.start(deviceUID: settings.inputDeviceUID.isEmpty ? nil : settings.inputDeviceUID)
        } catch {
            currentRecordingID = nil
            hotkey.setRecordingActive(false)
            transientHUD(.error(message: "Microphone unavailable", symbol: "mic.slash"),
                         dwell: Theme.errorDwell)
            sounds.dictationFailed()
            return
        }
        phase = .recording
        hotkey.setRecordingActive(true)
        sounds.dictationStarted()
    }

    func stopDictationAndTranscribe() {
        guard phase == .recording, let recordingID = currentRecordingID else { return }
        hotkey.setRecordingActive(false)

        let samples = microphone.stop()
        let duration = TimeInterval(samples.count) / TimeInterval(Self.sampleRate)

        guard duration >= Self.minimumUtteranceSeconds else {
            // Accidental tap — vanish silently.
            phase = .idle
            currentRecordingID = nil
            hud.hide()
            return
        }

        phase = .transcribing
        hud.show(.transcribing)

        let languageHint = settings.languageHint == "auto" ? nil : settings.languageHint
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.engine.transcribe(samples, languageHint: languageHint)
                await self.finishTranscription(result, recordingID: recordingID)
            } catch {
                await self.failTranscription(recordingID: recordingID)
            }
        }
    }

    func cancelDictation() {
        guard phase == .recording || phase == .transcribing else { return }
        hotkey.setRecordingActive(false)
        microphone.cancel()
        currentRecordingID = nil   // in-flight transcription becomes stale
        phase = .idle
        hud.hide()
    }

    // MARK: Completion

    private func finishTranscription(_ result: TranscriptionResult, recordingID: UUID) async {
        guard currentRecordingID == recordingID else { return }

        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            phase = .idle
            currentRecordingID = nil
            transientHUD(.error(message: "Didn't catch that.", symbol: "waveform"),
                         dwell: 1.4)
            return
        }

        let outcome = await inserter.insert(text)
        guard currentRecordingID == recordingID else { return }
        phase = .idle
        currentRecordingID = nil

        switch outcome {
        case .inserted:
            lastInsertedText = text
            history.add(text)
            sounds.dictationSucceeded()
            transientHUD(.success, dwell: Theme.successDwell)
        case .secureInputBlocked:
            history.add(text)   // don't lose the words — they're in history
            sounds.dictationFailed()
            transientHUD(.error(message: "Secure field — copied to history instead", symbol: "lock.fill"),
                         dwell: Theme.errorDwell)
        case .noAccessibilityPermission:
            history.add(text)
            sounds.dictationFailed()
            transientHUD(.error(message: "Grant Accessibility to insert text", symbol: "hand.raised"),
                         dwell: Theme.errorDwell)
        case .failed:
            history.add(text)
            sounds.dictationFailed()
            transientHUD(.error(message: "Couldn't insert — copied to history", symbol: "exclamationmark.triangle"),
                         dwell: Theme.errorDwell)
        }
    }

    private func failTranscription(recordingID: UUID) async {
        guard currentRecordingID == recordingID else { return }
        phase = .idle
        currentRecordingID = nil
        sounds.dictationFailed()
        transientHUD(.error(message: "Transcription failed", symbol: "exclamationmark.triangle"),
                     dwell: Theme.errorDwell)
    }

    /// Show a HUD state, then hide after `dwell`. Every terminal path funnels here
    /// or through `hud.hide()` — the HUD must never linger (see ARCHITECTURE.md).
    private func transientHUD(_ state: HUDState, dwell: TimeInterval) {
        hideTask?.cancel()
        hud.show(state)
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(dwell * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.hud.hide()
        }
    }
}
