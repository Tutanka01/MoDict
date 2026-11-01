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
    let vocabulary: VocabularyStore
    let usage: UsageStore
    let controller: DictationController

    private init() {
        let settings = SettingsStore()
        let history = HistoryStore()
        let vocabulary = VocabularyStore()
        let usage = UsageStore()
        self.settings = settings
        self.history = history
        self.vocabulary = vocabulary
        self.usage = usage
        self.controller = DictationController(settings: settings, history: history,
                                              vocabulary: vocabulary, usage: usage)
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
        case needsAPIKey
        case downloading(ModelDownloadProgress)
        case ready
        case failed(String)
    }

    enum UserIssue: Equatable {
        case microphonePermissionMissing
        case inputMonitoringPermissionMissing
        case microphoneMissing
        case microphoneUnavailable
        case accessibilityPermissionMissing
        case secureInputBlocked
        case insertionFailed(InsertOutcome.FailureReason)
        case transcriptionTimedOut
        case transcriptionFailed
        case cloudTranscriptionFailed(String)

        var symbol: String {
            switch self {
            case .microphonePermissionMissing, .microphoneMissing, .microphoneUnavailable:
                return "mic.slash"
            case .inputMonitoringPermissionMissing:
                return "keyboard"
            case .accessibilityPermissionMissing:
                return "hand.raised"
            case .secureInputBlocked:
                return "lock.fill"
            case .insertionFailed, .transcriptionTimedOut, .transcriptionFailed, .cloudTranscriptionFailed:
                return "exclamationmark.triangle"
            }
        }

        var hudMessage: String {
            switch self {
            case .microphonePermissionMissing:
                return "Allow Microphone to dictate"
            case .inputMonitoringPermissionMissing:
                return "Allow Input Monitoring"
            case .microphoneMissing:
                return "No microphone found"
            case .microphoneUnavailable:
                return "Microphone could not start"
            case .accessibilityPermissionMissing:
                return "Allow Accessibility to paste"
            case .secureInputBlocked:
                return "Secure Input blocked paste"
            case .insertionFailed:
                return "Could not insert — saved in Recent"
            case .transcriptionTimedOut:
                return "Transcription took too long"
            case .transcriptionFailed:
                return "Transcription failed"
            case .cloudTranscriptionFailed:
                return "Cloud transcription failed"
            }
        }

        var statusTitle: String {
            switch self {
            case .microphonePermissionMissing:
                return "Microphone permission missing"
            case .inputMonitoringPermissionMissing:
                return "Input Monitoring permission missing"
            case .microphoneMissing:
                return "No microphone detected"
            case .microphoneUnavailable:
                return "Microphone unavailable"
            case .accessibilityPermissionMissing:
                return "Accessibility permission missing"
            case .secureInputBlocked:
                return "Secure Input blocked insertion"
            case .insertionFailed:
                return "Insertion failed"
            case .transcriptionTimedOut:
                return "Transcription timed out"
            case .transcriptionFailed:
                return "Transcription failed"
            case .cloudTranscriptionFailed:
                return "Cloud transcription failed"
            }
        }

        var statusDetail: String {
            switch self {
            case .microphonePermissionMissing:
                return "Allow MoDict in Privacy & Security."
            case .inputMonitoringPermissionMissing:
                return "Enable MoDict in Input Monitoring, then try again."
            case .microphoneMissing:
                return "Connect or choose an input device."
            case .microphoneUnavailable:
                return "Try another input device, then dictate again."
            case .accessibilityPermissionMissing:
                return "Enable MoDict in Accessibility to send paste."
            case .secureInputBlocked:
                return "Turn off Secure Keyboard Entry or use another field."
            case .insertionFailed(let reason):
                switch reason {
                case .pasteboardWriteFailed:
                    return "MoDict could not prepare the pasteboard; text is saved in Recent."
                case .pasteShortcutFailed:
                    return "MoDict could not send Command-V; text is saved in Recent."
                case .cancelled:
                    return "Insertion was cancelled before paste completed."
                }
            case .transcriptionTimedOut:
                return "Try a shorter utterance, or retry after the model settles."
            case .transcriptionFailed:
                return "Try again; no text was inserted."
            case .cloudTranscriptionFailed(let detail):
                return detail
            }
        }
    }

    @Published private(set) var phase: Phase = .idle {
        didSet { idleSleep.setActive(phase != .idle) }
    }
    @Published private(set) var modelState: ModelState = .unknown
    @Published private(set) var modelStates: [SpeechModel: ModelState] = [:]
    @Published private(set) var isManagingModel = false
    @Published private(set) var userIssue: UserIssue?
    @Published private(set) var lastInsertedText: String?
    /// Live transcript of the dictation in flight (vocabulary already applied);
    /// nil whenever no dictation is running. Updated ~1/s by the streaming engine.
    @Published private(set) var partialTranscript: PartialTranscript?

    let settings: SettingsStore
    let history: HistoryStore
    let vocabulary: VocabularyStore
    let usage: UsageStore

    private let hotkey: HotkeyMonitor
    private let microphone: MicrophoneCapture
    private let fluidAudioEngine: FluidAudioEngine
    private let qwenAudioEngine: QwenAudioEngine
    private let cloudEngines: [SpeechModel: OpenRouterEngine]
    private let inserter: TextInserter
    private let hud: HUDController
    private let sounds: SoundFeedback
    private let speechGate = SpeechGate()
    private let idleSleep = IdleSleepGuard()

    /// Identity of the recording in flight; async completions compare against it
    /// and drop themselves when stale (double-taps, rapid re-triggers).
    private var currentRecordingID: UUID?
    /// The live streaming session, if any. Boxed because the audio thread reads
    /// it inside `onChunk` while the main actor swaps it per utterance — the
    /// `onChunk` closure itself is set once and never mutated (tap-thread race).
    private let streamingSessionBox = StreamingSessionBox()
    /// Once the final text is on the HUD, straggler partial callbacks (already
    /// queued main-actor hops) must not overwrite it while insertion runs.
    private var partialSettled = false
    private var recordingStartedAt: TimeInterval = 0
    private var trace: DictationTrace?
    private var transcriptionTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var vocabularyHintsTask: Task<Void, Never>?

    /// Holds shorter than this are treated as accidental and dropped.
    private static let minimumUtteranceSeconds: TimeInterval = 0.35
    /// Capture past the physical release. Hex measured that releasing 100 ms before
    /// the end of the last word keeps it 7 times in 10, and 200 ms only 2 in 10.
    private static let releaseTail: TimeInterval = 0.2
    /// Parakeet refuses anything shorter (`ASRConstants`, 0.3 s), and a hold can end up
    /// with less audio than its length when the microphone was slow to open.
    private static let minimumEngineSamples = 4_800
    private nonisolated static let sampleRate = 16_000
    private static let minimumTranscriptionTimeout: TimeInterval = 30

    init(settings: SettingsStore, history: HistoryStore, vocabulary: VocabularyStore, usage: UsageStore) {
        self.settings = settings
        self.history = history
        self.vocabulary = vocabulary
        self.usage = usage
        self.hotkey = HotkeyMonitor()
        self.microphone = MicrophoneCapture()
        self.fluidAudioEngine = FluidAudioEngine()
        self.qwenAudioEngine = QwenAudioEngine()
        self.cloudEngines = Dictionary(uniqueKeysWithValues: SpeechModel.cloudModels.map {
            ($0, OpenRouterEngine(model: $0))
        })
        self.inserter = TextInserter(settings: settings)
        self.hud = HUDController(settings: settings)
        self.sounds = SoundFeedback(settings: settings)
        self.modelStates = Dictionary(uniqueKeysWithValues: SpeechModel.allCases.map {
            ($0, $0.isCloud ? (settings.hasOpenRouterKey ? .ready : .needsAPIKey)
                             : ($0.isDownloaded ? .ready : .needsDownload))
        })
        self.modelState = settings.speechModel.isCloud
            ? (settings.hasOpenRouterKey ? .unknown : .needsAPIKey)
            : (settings.speechModel.isDownloaded ? .unknown : .needsDownload)

        hotkey.mode = settings.hotkeyMode
        hotkey.key = settings.dictationKey
        hotkey.onBegin = { [weak self] in self?.startDictation() ?? false }
        hotkey.onEnd = { [weak self] in self?.stopDictationAndTranscribe() }
        hotkey.onCancel = { [weak self] in self?.cancelDictation() }
        hotkey.onHandsFree = { [weak self] in self?.handleHandsFree() }
        hotkey.onPermissionLost = { [weak self] in self?.handleInputMonitoringLost() }

        microphone.onLevel = { [weak self] level in
            DispatchQueue.main.async {
                self?.hud.setLevel(level)
            }
        }
        // Silence watchdog: a level hugging zero for seconds while recording is
        // almost always the wrong input device. Say so before the user finishes
        // a long dictation that transcribes to nothing.
        hud.onLevelSample = { [weak self] level in
            self?.observeRecordingLevel(level)
        }
        microphone.onChunk = { [box = streamingSessionBox] chunk in
            // Audio thread. `feed` is synchronous and non-blocking; a single
            // producer keeps the chunks ordered end-to-end.
            box.value?.feed(chunk)
        }
        microphone.onFatalInterruption = { [weak self] error, utterance in
            DispatchQueue.main.async {
                self?.handleMicrophoneInterruption(error, utterance: utterance)
            }
        }
    }

    // MARK: Lifecycle

    /// Start listening for the hotkey and load the model. Safe to call repeatedly.
    func activate() {
        hotkey.mode = settings.hotkeyMode
        hotkey.key = settings.dictationKey
        if !hotkey.start() {
            showUserIssue(.inputMonitoringPermissionMissing)
        }
        microphone.warmUp()
        prepareEngine()
        preparePreviewEngine()
        observeWorkspace()
        Task { await speechGate.prepare() }
        pushVocabularyHints()
    }

    /// Qwen takes the vocabulary as a context prompt. `$rules` yields the current list
    /// and then each change; one loop keeps them in order.
    private func pushVocabularyHints() {
        guard vocabularyHintsTask == nil else { return }
        vocabularyHintsTask = Task { [vocabulary, qwenAudioEngine] in
            for await rules in vocabulary.$rules.values {
                await qwenAudioEngine.setVocabularyHints(rules.map(\.replacement))
            }
        }
    }

    /// Re-reads TCC state and reconciles: re-arms the event tap once Input
    /// Monitoring appears, clears permission issues that no longer apply. TCC has
    /// no change notification, so without this a grant made in System Settings is
    /// invisible until relaunch. Cheap (three preflight calls) — safe to call often.
    func recheckPermissions() {
        if Permissions.inputMonitoringGranted {
            if hotkey.start(), userIssue == .inputMonitoringPermissionMissing {
                userIssue = nil
            }
        }
        if userIssue == .accessibilityPermissionMissing, Permissions.accessibilityGranted {
            userIssue = nil
        }
        if userIssue == .microphonePermissionMissing, Permissions.microphoneGranted {
            userIssue = nil
        }
    }

    private func observeWorkspace() {
        guard workspaceObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        func observe(_ name: Notification.Name, _ action: @escaping @MainActor (DictationController) -> Void) {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if let self { action(self) }
                }
            })
        }
        // The user grants permissions in System Settings, then switches back: any
        // app activation is the moment to reconcile. A wake can also leave the tap dead.
        observe(NSWorkspace.didActivateApplicationNotification) { $0.recheckPermissions() }
        observe(NSWorkspace.didWakeNotification) { $0.recheckPermissions() }
        // A recording cannot outlive the session it started in. Pasting after the wake
        // could land anywhere, so it is dropped. A transcription already running finishes.
        observe(NSWorkspace.willSleepNotification) { $0.abandonRecording() }
        observe(NSWorkspace.sessionDidResignActiveNotification) { $0.abandonRecording() }
    }

    private func abandonRecording() {
        guard phase == .recording else { return }
        hotkey.abandonSession()
        cancelDictation()
    }

    func deactivate() {
        cancelDictation()
        hotkey.stop()
    }

    /// Synchronous: nothing scheduled runs once `applicationWillTerminate` returns.
    func prepareForTermination() {
        deactivate()
        inserter.flushPendingRestore()
    }

    func refreshHotkeyConfiguration() {
        hotkey.mode = settings.hotkeyMode
        hotkey.key = settings.dictationKey
    }

    func setDictationEnabled(_ enabled: Bool) {
        settings.dictationEnabled = enabled
        if !enabled {
            hotkey.abandonSession()
            cancelDictation()
        }
    }

    /// Download (if needed) and load the selected model, publishing progress.
    func prepareEngine() {
        guard modelState != .ready else { return }
        downloadModel(settings.speechModel)
    }

    func downloadModel(_ model: SpeechModel) {
        guard !isManagingModel else { return }
        if model.isCloud && !settings.hasOpenRouterKey {
            setModelState(.needsAPIKey, for: model)
            return
        }
        let engine = engine(for: model)
        isManagingModel = true
        // Report "checking" at once, even before the first byte: the caller just
        // asked for a download, and a still-`.needsDownload` state would read as
        // if nothing happened until the first progress callback lands.
        setModelState(.downloading(ModelDownloadProgress(phase: .checking, fraction: 0)), for: model)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await engine.prepare { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.modelState(for: model) != .ready,
                              !model.isCloud || self.settings.hasOpenRouterKey else { return }
                        self.setModelState(.downloading(progress), for: model)
                    }
                }
                self.setModelState(model.isCloud && !self.settings.hasOpenRouterKey
                    ? .needsAPIKey : .ready, for: model)
                if self.settings.speechModel != model {
                    await engine.unload()
                }
            } catch {
                self.setModelState(.failed(error.localizedDescription), for: model)
            }
            self.isManagingModel = false
            // A freshly downloaded Parakeet (or one just unloaded above) may be
            // the preview engine for the selected model.
            self.preparePreviewEngine()
        }
    }

    func selectModel(_ model: SpeechModel) {
        guard settings.speechModel != model else { return }
        hotkey.abandonSession()
        cancelDictation()
        let previous = settings.speechModel
        settings.speechModel = model
        modelState = (model.isCloud && !settings.hasOpenRouterKey) ? .needsAPIKey
            : (model.isCloud || model.isDownloaded)
            ? .downloading(ModelDownloadProgress(phase: .checking, fraction: 0))
            : .needsDownload
        modelStates[model] = modelState
        Task { [weak self] in
            guard let self else { return }
            await self.engine(for: previous).unload()
            if model.isCloud || model.isDownloaded { self.prepareEngine() }
            self.preparePreviewEngine()
        }
    }

    func refreshCloudKeyState() {
        if settings.speechModel.isCloud {
            hotkey.abandonSession()
            cancelDictation()
        }
        for model in SpeechModel.cloudModels {
            setModelState(settings.hasOpenRouterKey ? .unknown : .needsAPIKey, for: model)
        }
        if settings.speechModel.isCloud && settings.hasOpenRouterKey { prepareEngine() }
    }

    func deleteModel(_ model: SpeechModel) {
        guard !model.isCloud else { return }
        guard !isManagingModel else { return }
        hotkey.abandonSession()
        cancelDictation()
        isManagingModel = true
        setModelState(.downloading(ModelDownloadProgress(phase: .checking, fraction: 0)), for: model)
        let engine = engine(for: model)
        Task { [weak self] in
            guard let self else { return }
            await engine.unload()
            do {
                switch model {
                case .qwen3ASR1_7B: try QwenAudioEngine.deleteModels()
                case .parakeetV3:
                    if FileManager.default.fileExists(atPath: FluidAudioEngine.modelsDirectory.path) {
                        try FileManager.default.removeItem(at: FluidAudioEngine.modelsDirectory)
                    }
                case .maiTranscribe2, .museVoiceTranscribe, .gptTranscribe: break
                }
                self.setModelState(.needsDownload, for: model)
            } catch {
                self.setModelState(.failed(error.localizedDescription), for: model)
            }
            self.isManagingModel = false
        }
    }

    func modelState(for model: SpeechModel) -> ModelState {
        modelStates[model] ?? (model.isCloud
            ? (settings.hasOpenRouterKey ? .ready : .needsAPIKey)
            : (model.isDownloaded ? .ready : .needsDownload))
    }

    private func setModelState(_ state: ModelState, for model: SpeechModel) {
        modelStates[model] = state
        if settings.speechModel == model { modelState = state }
    }

    private func engine(for model: SpeechModel) -> any TranscriptionEngine {
        switch model {
        case .qwen3ASR1_7B: qwenAudioEngine
        case .parakeetV3: fluidAudioEngine
        case .maiTranscribe2, .museVoiceTranscribe, .gptTranscribe: cloudEngines[model]!
        }
    }

    private var selectedEngine: any TranscriptionEngine {
        engine(for: settings.speechModel)
    }

    /// The engine streaming the live preview: the selected one when it streams
    /// (Parakeet); otherwise Parakeet running on this Mac for the preview
    /// only, when Live preview is on and its model is on disk. Preview-only
    /// either way: the paste always comes from the selected engine's batch pass.
    private var previewEngine: (any TranscriptionEngine)? {
        if settings.speechModel == .parakeetV3 { return fluidAudioEngine }
        guard settings.livePreview, SpeechModel.parakeetV3.isDownloaded else { return nil }
        return fluidAudioEngine
    }

    /// Loads (or releases) Parakeet as the preview engine for models that
    /// don't stream. Never downloads: without the model on disk there is
    /// simply no preview. Safe to call repeatedly.
    func preparePreviewEngine() {
        guard settings.speechModel != .parakeetV3, !isManagingModel else { return }
        let engine = fluidAudioEngine
        if settings.livePreview, SpeechModel.parakeetV3.isDownloaded {
            Task { try? await engine.prepare { _ in } }
        } else {
            Task { await engine.unload() }
        }
    }

    // MARK: Dictation flow

    @discardableResult
    func startDictation() -> Bool {
        guard settings.dictationEnabled, phase == .idle else { return false }
        guard case .ready = modelState else {
            let issue = modelNotReadyHUD(for: modelState)
            transientHUD(.error(message: issue.message, symbol: issue.symbol), dwell: Theme.errorDwell)
            return false
        }
        guard Permissions.microphoneGranted else {
            showUserIssue(.microphonePermissionMissing)
            return false
        }

        // Retries a failed download at the next dictation, and covers a first
        // dictation reached through setup, before `activate()` has run.
        Task { await speechGate.prepare() }

        let recordingID = UUID()
        currentRecordingID = recordingID
        recordingStartedAt = hotkey.lastPressedAt
        trace = DictationTrace(modelID: settings.speechModel.rawValue, pressedAt: recordingStartedAt)
        trace?.mark(.begin)

        // HUD first: it must be on screen at key-down, before audio flows.
        hideTask?.cancel()
        hud.setActionHint(recordingActionHint)
        hud.show(.recording)
        silenceWatchdogStart()
        partialTranscript = nil
        partialSettled = false
        hud.setPartial(nil)
        // Live partials are best-effort: the session buffers audio from the very
        // first chunk while the recognizer spins up in the background; a start
        // failure only means no streaming preview — batch still transcribes.
        streamingSessionBox.value = previewEngine?.startStreamingSession(
            languageHint: settings.languageHint
        ) { [weak self] partial in
            Task { @MainActor [weak self] in
                self?.handlePartial(partial, recordingID: recordingID)
            }
        }
        // Cue before capture: on built-in speakers the chime otherwise bleeds
        // into the first phoneme and the model hears a degraded opening word.
        sounds.dictationStarted()
        do {
            try microphone.start(
                deviceUID: settings.inputDeviceUID.isEmpty ? nil : settings.inputDeviceUID,
                avoidBluetooth: settings.avoidBluetoothMicrophone)
        } catch {
            if let session = streamingSessionBox.take() {
                Task { await session.cancel() }
            }
            currentRecordingID = nil
            hotkey.setRecordingActive(false)
            endTrace(.microphoneFailed)
            showUserIssue(microphoneIssue(for: error))
            sounds.dictationFailed()
            return false
        }
        userIssue = nil
        phase = .recording
        hotkey.setRecordingActive(true)
        return true
    }

    func stopDictationAndTranscribe() {
        guard phase == .recording, let recordingID = currentRecordingID else { return }

        // Judged on the physical hold, at once: a tap must not wait out a tail, and
        // a microphone still opening must not make a real hold look accidental.
        let heldFor = ProcessInfo.processInfo.systemUptime - recordingStartedAt
        trace?.mark(.hold)
        guard heldFor >= Self.minimumUtteranceSeconds else {
            // Accidental tap — vanish silently (including the streaming session).
            endTrace(.tap)
            microphone.cancel()
            if let session = streamingSessionBox.take() {
                Task { await session.cancel() }
            }
            phase = .idle
            currentRecordingID = nil
            partialTranscript = nil
            hud.setPartial(nil)
            hotkey.setRecordingActive(false)
            hud.hide()
            return
        }

        phase = .transcribing
        hotkey.setRecordingActive(true)
        // The HUD keeps showing the last partial next to the dots, so the text
        // visually settles into the final instead of blanking.
        hud.show(.transcribing)

        let languageHint = settings.languageHint == "auto" ? nil : settings.languageHint
        // Capture the model now: the result landing may trail the request, and
        // the usage record must name the model that actually ran.
        let model = settings.speechModel
        transcriptionTask?.cancel()
        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            // People release before the end of their last word; the tail keeps it.
            // A cancel during it makes this return early and the guard ends the task.
            let samples = await self.microphone.finish(tail: Self.releaseTail)
            guard self.currentRecordingID == recordingID else { return }
            self.trace?.mark(.tail)
            self.trace?.noteAudio(seconds: TimeInterval(samples.count) / TimeInterval(Self.sampleRate))
            let session = self.streamingSessionBox.take()
            // Silence and noise make the models write words nobody said, and a cloud
            // model would bill for them, so nothing without speech reaches an engine.
            let hasSpeech: Bool
            if samples.count < Self.minimumEngineSamples {
                // A dead microphone is not silence: say what is actually wrong.
                if let failure = self.microphone.takeCaptureFailure() {
                    self.failCapture(failure, recordingID: recordingID)
                    Task { await session?.cancel() }
                    return
                }
                hasSpeech = false
            } else if case .speech = await self.speechGate.evaluate(samples) {
                hasSpeech = true
            } else {
                hasSpeech = false
            }
            // Esc during the gate: a stale decode would only hold up the engine, and
            // the trace may already be a newer dictation's.
            guard self.currentRecordingID == recordingID else {
                Task { await session?.cancel() }
                return
            }
            self.trace?.mark(.gate)
            guard hasSpeech else {
                self.endTrace(.noSpeech)
                self.settleWithoutWords(recordingID: recordingID)
                Task { await session?.cancel() }
                return
            }
            // After the tail, so capture time never eats into the transcription's.
            let duration = TimeInterval(samples.count) / TimeInterval(Self.sampleRate)
            let timeout = Self.transcriptionTimeout(forAudioDuration: duration, cloud: model.isCloud)
            do {
                let result = try await self.transcribeWithTimeout(
                    samples,
                    languageHint: languageHint,
                    timeout: timeout,
                    session: session
                )
                self.trace?.mark(.engine)
                await self.finishTranscription(result, recordingID: recordingID, model: model)
            } catch {
                // Unblock the user first: the session may be what wedged.
                await self.failTranscription(error, recordingID: recordingID)
                Task { await session?.cancel() }
            }
        }
    }

    private func failCapture(_ error: MicrophoneCapture.CaptureError, recordingID: UUID) {
        guard currentRecordingID == recordingID else { return }
        phase = .idle
        currentRecordingID = nil
        transcriptionTask = nil
        partialTranscript = nil
        hud.setPartial(nil)
        hotkey.setRecordingActive(false)
        endTrace(.microphoneFailed)
        sounds.dictationFailed()
        showUserIssue(microphoneIssue(for: error))
    }

    /// One line per dictation, numbers and labels only.
    private func endTrace(_ outcome: DictationTrace.Outcome) {
        guard let trace else { return }
        self.trace = nil
        let line = trace.summary(outcome: outcome)
        Log.dictation.info("\(line, privacy: .public)")
    }

    /// Nothing to paste: no audio, no speech, or an empty transcript.
    private func settleWithoutWords(recordingID: UUID) {
        guard currentRecordingID == recordingID else { return }
        phase = .idle
        currentRecordingID = nil
        transcriptionTask = nil
        partialTranscript = nil
        hud.setPartial(nil)
        hotkey.setRecordingActive(false)
        transientHUD(.error(message: "Didn't catch that.", symbol: "waveform"), dwell: 1.4)
    }

    func cancelDictation() {
        guard phase == .recording || phase == .transcribing else { return }
        endTrace(.cancelled)
        hotkey.setRecordingActive(false)
        microphone.cancel()
        if let session = streamingSessionBox.take() {
            Task { await session.cancel() }
        }
        transcriptionTask?.cancel()
        transcriptionTask = nil
        currentRecordingID = nil   // in-flight transcription becomes stale
        phase = .idle
        partialTranscript = nil
        hud.setPartial(nil)
        hud.hide()
    }

    // MARK: Completion

    private func finishTranscription(_ result: TranscriptionResult,
                                     recordingID: UUID,
                                     model: SpeechModel) async {
        guard currentRecordingID == recordingID else { return }

        // A successful response is billed even when the text turns out empty or
        // the paste cannot land, so the usage record happens before any early
        // return. Failures never reach this method — failed generations are not billed.
        await usage.record(UsageRecord(
            modelID: model.rawValue,
            isCloud: model.isCloud,
            audioSeconds: result.audioDuration,
            processingSeconds: result.processingTime,
            inputTokens: result.usage?.inputTokens,
            outputTokens: result.usage?.outputTokens,
            costUSD: result.usage?.costUSD
        ))
        // Esc during the ledger write: nothing below applies to a cancelled dictation.
        guard currentRecordingID == recordingID else { return }
        let cost = result.usage?.costUSD

        // Personal vocabulary runs before the empty-check: a rule can delete the
        // whole utterance, which then takes the "Didn't catch that." path.
        let cleaned = TranscriptSanitizer.clean(result.text)
        let text = vocabulary.apply(to: cleaned)
        guard !text.isEmpty else {
            endTrace(.empty)
            settleWithoutWords(recordingID: recordingID)
            return
        }

        // Settle the HUD text onto the final transcript while insertion runs.
        partialSettled = true
        let settled = PartialTranscript(confirmedText: text, volatileText: "")
        partialTranscript = settled
        hud.setPartial(settled)

        let outcome = await inserter.insert(text)
        guard currentRecordingID == recordingID else {
            // Cancelled while the paste was being posted: the text landed anyway,
            // so the words must still be in Recent.
            if outcome == .inserted {
                lastInsertedText = text
                history.add(text, costUSD: cost)
            }
            return
        }
        phase = .idle
        currentRecordingID = nil
        transcriptionTask = nil
        partialTranscript = nil
        hud.setPartial(nil)
        hotkey.setRecordingActive(false)
        trace?.mark(.paste)

        switch outcome {
        case .inserted:
            endTrace(.pasted)
            userIssue = nil
            lastInsertedText = text
            history.add(text, costUSD: cost)
            sounds.dictationSucceeded()
            settings.recordGuidedDictation()
            hud.setInsertedWordCount(text.split(whereSeparator: \.isWhitespace).count)
            transientHUD(.success, dwell: Theme.successDwell)
        case .secureInputBlocked:
            endTrace(.secureInput)
            history.add(text, costUSD: cost)   // don't lose the words — they're in history
            sounds.dictationFailed()
            showUserIssue(.secureInputBlocked)
        case .noAccessibilityPermission:
            endTrace(.noAccessibility)
            history.add(text, costUSD: cost)
            sounds.dictationFailed()
            showUserIssue(.accessibilityPermissionMissing)
        case .failed(let reason):
            endTrace(.pasteFailed)
            history.add(text, costUSD: cost)
            sounds.dictationFailed()
            showUserIssue(.insertionFailed(reason))
        }
    }

    private func failTranscription(_ error: Error, recordingID: UUID) async {
        guard currentRecordingID == recordingID else { return }
        endTrace(error is TranscriptionTimeoutError ? .timeout : .failed)
        phase = .idle
        currentRecordingID = nil
        transcriptionTask = nil
        partialTranscript = nil
        hud.setPartial(nil)
        hotkey.setRecordingActive(false)
        sounds.dictationFailed()
        if error is CancellationError {
            hud.hide()
        } else if error is TranscriptionTimeoutError {
            showUserIssue(.transcriptionTimedOut)
        } else if let cloudError = error as? OpenRouterError {
            showUserIssue(.cloudTranscriptionFailed(cloudError.localizedDescription))
        } else if settings.speechModel.isCloud {
            showUserIssue(.cloudTranscriptionFailed("Check your connection and try again."))
        } else {
            showUserIssue(.transcriptionFailed)
        }
    }

    private func showUserIssue(_ issue: UserIssue) {
        userIssue = issue
        transientHUD(.error(message: issue.hudMessage, symbol: issue.symbol), dwell: Theme.errorDwell)
    }

    private func microphoneIssue(for error: Error) -> UserIssue {
        if let captureError = error as? MicrophoneCapture.CaptureError {
            switch captureError {
            case .noInputDevice:
                return .microphoneMissing
            case .selectedDeviceUnavailable, .deviceSelectionFailed, .invalidFormat, .engineStartFailed:
                return .microphoneUnavailable
            }
        }
        return .microphoneUnavailable
    }

    private func modelNotReadyHUD(for state: ModelState) -> (message: String, symbol: String) {
        switch state {
        case .unknown:
            return ("Speech model is starting", "ellipsis.circle")
        case .needsDownload:
            return ("Speech model needs download", "arrow.down.circle")
        case .needsAPIKey:
            return ("Add an OpenRouter API key in Settings", "key")
        case .downloading(let progress):
            switch progress.phase {
            case .checking:
                return ("Checking speech model", "arrow.down.circle")
            case .downloading:
                let pct = Int((progress.fraction * 100).rounded())
                return ("Downloading model \(pct)%", "arrow.down.circle")
            case .compiling:
                return ("Preparing speech model", "arrow.down.circle")
            case .ready:
                return ("Speech model is almost ready", "arrow.down.circle")
            }
        case .ready:
            return ("Speech model is ready", "waveform")
        case .failed:
            return ("Model setup failed — retry in menu", "exclamationmark.triangle")
        }
    }

    private func handleInputMonitoringLost() {
        hotkey.abandonSession()
        guard phase == .recording || phase == .transcribing else {
            showUserIssue(.inputMonitoringPermissionMissing)
            return
        }
        cancelDictation()
        sounds.dictationFailed()
        showUserIssue(.inputMonitoringPermissionMissing)
    }

    private var recordingActionHint: String {
        switch settings.hotkeyMode {
        case .pushToTalk, .hybrid:
            // The exact stop gesture while the key is held (DESIGN.md). The
            // hybrid tap alternative is taught by the setup guide and the
            // menu bar — the HUD row is too tight for both, and squeezing
            // them in is what stacked the title vertically.
            return "Release to paste"
        case .toggle:
            return "Press again to paste"
        }
    }

    // MARK: Silence watchdog

    /// Warns once, after sustained silence, that nothing is being heard — long
    /// before the transcription comes back empty. Recovers on the first real
    /// signal without resetting the session.
    private func observeRecordingLevel(_ level: Float) {
        guard phase == .recording else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if level >= Self.silenceLevelFloor {
            silenceStartedAt = nil
            if silenceWarned {
                silenceWarned = false
                hud.setSilenceWarning(false)
            }
            return
        }
        let silentSince = silenceStartedAt ?? now
        silenceStartedAt = silentSince
        let elapsed = now - recordingStartedAt
        if !silenceWarned, now - silentSince >= Self.silenceWarningSeconds, elapsed >= Self.silenceGraceSeconds {
            silenceWarned = true
            hud.setSilenceWarning(true)
        }
    }

    private func silenceWatchdogStart() {
        silenceStartedAt = nil
        silenceWarned = false
    }

    private static let silenceLevelFloor: Float = 0.02
    /// 2.5 s of near-zero level, measured in time: level samples arrive once
    /// per audio buffer (~12 Hz), not per frame. A 1.5 s grace means a slow
    /// speaker opening is never flagged.
    private static let silenceWarningSeconds: TimeInterval = 2.5
    private static let silenceGraceSeconds: TimeInterval = 1.5
    private var silenceStartedAt: TimeInterval?
    private var silenceWarned = false

    private func handleHandsFree() {
        guard phase == .recording else { return }
        // Persistent: the way to stop just changed mid-session, so say so even
        // after the hold gesture is learned.
        hud.setActionHint("Press again to paste", persistent: true)
    }

    private func handleMicrophoneInterruption(_ error: MicrophoneCapture.CaptureError, utterance: UInt64) {
        // Past `.recording`, `finish` already returned what there was. The utterance
        // check drops a failure that hopped here while a newer recording started.
        guard phase == .recording, microphone.isCurrent(utterance: utterance) else { return }
        endTrace(.microphoneFailed)
        microphone.cancel()   // the audio of a dead session has no reason to stay around
        hotkey.abandonSession()
        hotkey.setRecordingActive(false)
        if let session = streamingSessionBox.take() {
            Task { await session.cancel() }
        }
        currentRecordingID = nil
        phase = .idle
        partialTranscript = nil
        hud.setPartial(nil)
        sounds.dictationFailed()
        showUserIssue(microphoneIssue(for: error))
    }

    /// Streaming partials hop here onto the main actor. Stale recordings are
    /// dropped; partials keep flowing during `.transcribing` so the settling
    /// text tracks the final windows being drained.
    private func handlePartial(_ partial: PartialTranscript, recordingID: UUID) {
        guard currentRecordingID == recordingID, phase != .idle, !partialSettled else { return }
        let display = PartialTranscript(
            confirmedText: vocabulary.apply(to: partial.confirmedText),
            volatileText: vocabulary.apply(to: partial.volatileText)
        )
        partialTranscript = display
        hud.setPartial(display)
    }

    private static func transcriptionTimeout(forAudioDuration duration: TimeInterval, cloud: Bool) -> TimeInterval {
        max(cloud ? 75 : minimumTranscriptionTimeout, duration * 4 + 5)
    }

    private func transcribeWithTimeout(_ samples: [Float],
                                       languageHint: String?,
                                       timeout: TimeInterval,
                                       session: (any StreamingTranscriptionSession)?) async throws -> TranscriptionResult {
        let engine = selectedEngine
        return try await Deadline.run(seconds: timeout, timeoutError: { TranscriptionTimeoutError() }) {
            try await Self.finalTranscription(
                samples, languageHint: languageHint, session: session, engine: engine)
        }
    }

    /// Streaming is deliberately preview-only. FluidAudio's sliding windows
    /// overlap and can occasionally reconstruct the same phrase more than once;
    /// treating that reconstruction as the paste payload produced very large,
    /// repeated blocks. On release we transcribe the captured utterance exactly
    /// once through the batch manager and paste only that canonical result.
    private nonisolated static func finalTranscription(
        _ samples: [Float],
        languageHint: String?,
        session: (any StreamingTranscriptionSession)?,
        engine: any TranscriptionEngine
    ) async throws -> TranscriptionResult {
        guard let session else {
            return try await engine.transcribe(samples, languageHint: languageHint)
        }

        // Stop overlapping-window inference before running the canonical pass.
        // Both managers share the loaded Core ML models; serializing them avoids
        // contention and makes release-time behavior deterministic.
        await session.cancel()
        return try await engine.transcribe(samples, languageHint: languageHint)
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

private struct TranscriptionTimeoutError: Error {}

/// Hands the live streaming session across the main-actor/audio-thread boundary.
/// The main actor swaps sessions per utterance while the tap thread reads inside
/// `onChunk`, hence the lock.
private final class StreamingSessionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var session: (any StreamingTranscriptionSession)?

    var value: (any StreamingTranscriptionSession)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return session
        }
        set {
            lock.lock()
            session = newValue
            lock.unlock()
        }
    }

    /// Atomically detach the current session.
    func take() -> (any StreamingTranscriptionSession)? {
        lock.lock()
        defer { lock.unlock() }
        let taken = session
        session = nil
        return taken
    }
}
