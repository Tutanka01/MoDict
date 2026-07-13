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
    let controller: DictationController

    private init() {
        let settings = SettingsStore()
        let history = HistoryStore()
        let vocabulary = VocabularyStore()
        self.settings = settings
        self.history = history
        self.vocabulary = vocabulary
        self.controller = DictationController(settings: settings, history: history, vocabulary: vocabulary)
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
            case .insertionFailed, .transcriptionTimedOut, .transcriptionFailed:
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
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var modelState: ModelState = .unknown
    @Published private(set) var userIssue: UserIssue?
    @Published private(set) var lastInsertedText: String?
    /// Live transcript of the dictation in flight (vocabulary already applied);
    /// nil whenever no dictation is running. Updated ~1/s by the streaming engine.
    @Published private(set) var partialTranscript: PartialTranscript?

    let settings: SettingsStore
    let history: HistoryStore
    let vocabulary: VocabularyStore

    private let hotkey: HotkeyMonitor
    private let microphone: MicrophoneCapture
    private let engine: FluidAudioEngine
    private let inserter: TextInserter
    private let hud: HUDController
    private let sounds: SoundFeedback

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
    private var prepareTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var workspaceObserver: NSObjectProtocol?

    /// Recordings shorter than this are treated as accidental and dropped.
    private static let minimumUtteranceSeconds: TimeInterval = 0.35
    private nonisolated static let sampleRate = 16_000
    private static let minimumTranscriptionTimeout: TimeInterval = 30

    init(settings: SettingsStore, history: HistoryStore, vocabulary: VocabularyStore) {
        self.settings = settings
        self.history = history
        self.vocabulary = vocabulary
        self.hotkey = HotkeyMonitor()
        self.microphone = MicrophoneCapture()
        self.engine = FluidAudioEngine()
        self.inserter = TextInserter(settings: settings)
        self.hud = HUDController(settings: settings)
        self.sounds = SoundFeedback(settings: settings)

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
        microphone.onChunk = { [box = streamingSessionBox] chunk in
            // Audio thread. `feed` is synchronous and non-blocking; a single
            // producer keeps the chunks ordered end-to-end.
            box.value?.feed(chunk)
        }
        microphone.onFatalInterruption = { [weak self] error in
            DispatchQueue.main.async {
                self?.handleMicrophoneInterruption(error)
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
        observePermissionChanges()
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

    /// The user grants permissions in System Settings, then switches back — any
    /// app activation is the moment to reconcile.
    private func observePermissionChanges() {
        guard workspaceObserver == nil else { return }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.recheckPermissions() }
        }
    }

    func deactivate() {
        cancelDictation()
        hotkey.stop()
    }

    func refreshHotkeyConfiguration() {
        hotkey.mode = settings.hotkeyMode
        hotkey.key = settings.dictationKey
    }

    func setDictationEnabled(_ enabled: Bool) {
        settings.dictationEnabled = enabled
        if !enabled {
            cancelDictation()
        }
    }

    /// Download (if needed) and load the Parakeet model, publishing progress.
    /// `force` re-runs preparation even when the model is already loaded, so the
    /// Settings "Re-download" button has an effect in the `.ready` state.
    func prepareEngine(force: Bool = false) {
        guard prepareTask == nil else { return }
        if !force, modelState == .ready { return }
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

        let recordingID = UUID()
        currentRecordingID = recordingID
        recordingStartedAt = ProcessInfo.processInfo.systemUptime

        // HUD first: it must be on screen at key-down, before audio flows.
        hideTask?.cancel()
        hud.setActionHint(recordingActionHint)
        hud.show(.recording)
        partialTranscript = nil
        partialSettled = false
        hud.setPartial(nil)
        // Live partials are best-effort: the session buffers audio from the very
        // first chunk while the recognizer spins up in the background; a start
        // failure only means no streaming preview — batch still transcribes.
        streamingSessionBox.value = engine.startStreamingSession { [weak self] partial in
            Task { @MainActor [weak self] in
                self?.handlePartial(partial, recordingID: recordingID)
            }
        }
        do {
            try microphone.start(deviceUID: settings.inputDeviceUID.isEmpty ? nil : settings.inputDeviceUID)
        } catch {
            if let session = streamingSessionBox.take() {
                Task { await session.cancel() }
            }
            currentRecordingID = nil
            hotkey.setRecordingActive(false)
            showUserIssue(microphoneIssue(for: error))
            sounds.dictationFailed()
            return false
        }
        userIssue = nil
        phase = .recording
        hotkey.setRecordingActive(true)
        sounds.dictationStarted()
        return true
    }

    func stopDictationAndTranscribe() {
        guard phase == .recording, let recordingID = currentRecordingID else { return }

        let samples = microphone.stop()
        let session = streamingSessionBox.take()
        let duration = TimeInterval(samples.count) / TimeInterval(Self.sampleRate)

        guard duration >= Self.minimumUtteranceSeconds else {
            // Accidental tap — vanish silently (including the streaming session).
            if let session {
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
        let timeout = Self.transcriptionTimeout(forAudioDuration: duration)
        transcriptionTask?.cancel()
        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.transcribeWithTimeout(
                    samples,
                    languageHint: languageHint,
                    timeout: timeout,
                    session: session
                )
                await self.finishTranscription(result, recordingID: recordingID)
            } catch {
                // Idempotent; drops a session a timeout left mid-finish.
                await session?.cancel()
                await self.failTranscription(error, recordingID: recordingID)
            }
        }
    }

    func cancelDictation() {
        guard phase == .recording || phase == .transcribing else { return }
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

    private func finishTranscription(_ result: TranscriptionResult, recordingID: UUID) async {
        guard currentRecordingID == recordingID else { return }

        // Personal vocabulary runs before the empty-check: a rule can delete the
        // whole utterance, which then takes the "Didn't catch that." path.
        let cleaned = TranscriptSanitizer.clean(result.text)
        let text = vocabulary.apply(to: cleaned)
        guard !text.isEmpty else {
            phase = .idle
            currentRecordingID = nil
            transcriptionTask = nil
            partialTranscript = nil
            hud.setPartial(nil)
            hotkey.setRecordingActive(false)
            transientHUD(.error(message: "Didn't catch that.", symbol: "waveform"),
                         dwell: 1.4)
            return
        }

        // Settle the HUD text onto the final transcript while insertion runs.
        partialSettled = true
        let settled = PartialTranscript(confirmedText: text, volatileText: "")
        partialTranscript = settled
        hud.setPartial(settled)

        let outcome = await inserter.insert(text)
        guard currentRecordingID == recordingID else { return }
        phase = .idle
        currentRecordingID = nil
        transcriptionTask = nil
        partialTranscript = nil
        hud.setPartial(nil)
        hotkey.setRecordingActive(false)

        switch outcome {
        case .inserted:
            userIssue = nil
            lastInsertedText = text
            history.add(text)
            sounds.dictationSucceeded()
            transientHUD(.success, dwell: Theme.successDwell)
        case .secureInputBlocked:
            history.add(text)   // don't lose the words — they're in history
            sounds.dictationFailed()
            showUserIssue(.secureInputBlocked)
        case .noAccessibilityPermission:
            history.add(text)
            sounds.dictationFailed()
            showUserIssue(.accessibilityPermissionMissing)
        case .failed(let reason):
            history.add(text)
            sounds.dictationFailed()
            showUserIssue(.insertionFailed(reason))
        }
    }

    private func failTranscription(_ error: Error, recordingID: UUID) async {
        guard currentRecordingID == recordingID else { return }
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
        case .pushToTalk:
            return "Release to paste"
        case .toggle:
            return "Press again to paste"
        case .hybrid:
            return "Release to paste · tap for hands-free"
        }
    }

    private func handleHandsFree() {
        guard phase == .recording else { return }
        hud.setActionHint("Press again to paste")
    }

    private func handleMicrophoneInterruption(_ error: MicrophoneCapture.CaptureError) {
        guard phase == .recording else { return }
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

    private static func transcriptionTimeout(forAudioDuration duration: TimeInterval) -> TimeInterval {
        max(minimumTranscriptionTimeout, duration * 4 + 5)
    }

    private func transcribeWithTimeout(_ samples: [Float],
                                       languageHint: String?,
                                       timeout: TimeInterval,
                                       session: (any StreamingTranscriptionSession)?) async throws -> TranscriptionResult {
        let engine = self.engine
        return try await withThrowingTaskGroup(of: TranscriptionResult.self) { group in
            group.addTask {
                try await Self.finalTranscription(
                    samples, languageHint: languageHint, session: session, engine: engine)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw TranscriptionTimeoutError()
            }
            guard let result = try await group.next() else {
                throw TranscriptionTimeoutError()
            }
            group.cancelAll()
            return result
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
        engine: FluidAudioEngine
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
