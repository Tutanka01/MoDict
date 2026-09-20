import SwiftUI
import Combine

/// Five-step first-run flow: welcome → microphone → keyboard permissions → speech
/// model → live try-it. Steps advance automatically the moment their condition is
/// met (permission granted, model ready). Required permissions and the model are
/// never skippable; `onFinish` hands window dismissal back to
/// `OnboardingController`.
struct OnboardingView: View {

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let onFinish: () -> Void
    @ObservedObject private var settings: SettingsStore
    @ObservedObject private var controller: DictationController

    init(app: AppModel, onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        self._settings = ObservedObject(wrappedValue: app.settings)
        self._controller = ObservedObject(wrappedValue: app.controller)
    }

    private static let stepCount = 5

    @State private var step = 0
    @State private var micGranted = false
    @State private var accessibilityGranted = false
    @State private var inputMonitoringGranted = false
    @State private var micRequestInFlight = false
    @State private var tryItSucceeded = false
    @State private var tryText = ""
    /// The step an auto-advance is currently scheduled for, so we don't stack them.
    @State private var autoAdvancePending: Int?
    @State private var pollTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ZStack {
                stepView(for: step)
                    .id(step)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .frame(width: 520, height: 600)
        .onAppear { refreshPermissions() }
        .onReceive(pollTimer) { _ in refreshPermissions() }
        .onChange(of: step) { _, newStep in handleStepChange(to: newStep) }
        .onChange(of: controller.modelState) { _, _ in handleReadinessChange() }
        .onChange(of: controller.lastInsertedText) { _, newValue in handleInsertion(newValue) }
        .onKeyPress(.leftArrow) { goBack(); return .handled }
        .onKeyPress(.rightArrow) { advanceIfReady(); return .handled }
        .transaction { if reduceMotion { $0.animation = nil } }
    }

    // MARK: Chrome

    private var topBar: some View {
        VStack(spacing: 24) {
            HStack(spacing: 10) {
                if step > 0 {
                    Button(action: goBack) {
                        Image(systemName: "chevron.left")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("[", modifiers: .command)
                    .accessibilityLabel("Previous setup step")
                }
                Text("MoDict").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("SETUP  ·  \(step + 1) OF \(Self.stepCount)")
                    .font(.system(size: 10, weight: .medium)).tracking(1)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                ForEach(Array(["Welcome", "Microphone", "Access", "Model", "Try it"].enumerated()), id: \.offset) { index, title in
                    VStack(alignment: .leading, spacing: 8) {
                        Capsule().fill(.primary.opacity(index <= step ? 0.8 : 0.1)).frame(height: 3)
                        Text(title)
                            .font(.system(size: 10, weight: index == step ? .semibold : .regular))
                            .foregroundStyle(index == step ? .primary : .secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Setup step \(step + 1) of \(Self.stepCount)")
        }
        .padding(.horizontal, 32)
        .padding(.top, 24)
        .padding(.bottom, 12)
    }

    private var footer: some View {
        VStack(spacing: 12) {
            primaryButton
            Text(step == 0 ? "Created by Mohamad El Akhal" : "Your settings can be changed at any time.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 40)
        .padding(.bottom, 24)
        .padding(.top, 12)
    }

    private var primaryButton: some View {
        let config = primaryConfig
        return Button(action: config.action) {
            Text(config.title)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(.primary)
        .disabled(!config.enabled)
        .keyboardShortcut(.defaultAction)
    }

    // MARK: Steps

    @ViewBuilder
    private func stepView(for step: Int) -> some View {
        switch step {
        case 0:
            OnboardingWelcomeStep(key: settings.dictationKey, mode: settings.hotkeyMode)
        case 1:
            OnboardingMicrophoneStep(granted: micGranted, cloud: settings.speechModel.isCloud)
        case 2:
            OnboardingPermissionsStep(
                accessibilityGranted: accessibilityGranted,
                inputMonitoringGranted: inputMonitoringGranted,
                key: settings.dictationKey,
                onOpenAccessibility: openAccessibility,
                onOpenInputMonitoring: openInputMonitoring
            )
        case 3:
            OnboardingModelStep(settings: settings, controller: controller)
        default:
            OnboardingTryItStep(text: $tryText, succeeded: tryItSucceeded,
                                ready: allRequirementsReady, key: settings.dictationKey, mode: settings.hotkeyMode)
        }
    }

    private var keyboardPermissionsReady: Bool {
        accessibilityGranted && inputMonitoringGranted
    }

    private var modelReady: Bool {
        if case .ready = controller.modelState { return true }
        return false
    }

    private var allRequirementsReady: Bool {
        micGranted && keyboardPermissionsReady && modelReady
    }

    private var firstBlockingStep: Int? {
        if !micGranted { return 1 }
        if !keyboardPermissionsReady { return 2 }
        if !modelReady { return 3 }
        return nil
    }

    // MARK: Primary action per step

    private var primaryConfig: OnboardingPrimaryConfig {
        switch step {
        case 0:
            return OnboardingPrimaryConfig(title: "Get started", enabled: true, action: advance)
        case 1:
            if micGranted {
                return OnboardingPrimaryConfig(title: "Continue", enabled: true, action: advance)
            } else if micRequestInFlight {
                return OnboardingPrimaryConfig(title: "Waiting for macOS…", enabled: false) {}
            } else if Permissions.microphoneDenied {
                return OnboardingPrimaryConfig(title: "Open Microphone Settings", enabled: true) {
                    Permissions.openSettings(pane: .microphone)
                }
            } else {
                return OnboardingPrimaryConfig(title: "Allow microphone", enabled: !micRequestInFlight, action: requestMicrophone)
            }
        case 2:
            if keyboardPermissionsReady {
                return OnboardingPrimaryConfig(title: "Continue", enabled: true, action: advance)
            } else {
                return OnboardingPrimaryConfig(title: keyboardPermissionStatusTitle, enabled: false) {}
            }
        case 3:
            return modelPrimaryConfig
        default:
            if allRequirementsReady {
                return OnboardingPrimaryConfig(title: "Start dictating", enabled: true, action: finish)
            } else {
                return OnboardingPrimaryConfig(title: "Review setup", enabled: true, action: moveToFirstBlockingStep)
            }
        }
    }

    private var keyboardPermissionStatusTitle: String {
        if !accessibilityGranted && !inputMonitoringGranted { return "Waiting for both permissions" }
        if !accessibilityGranted { return "Waiting for Accessibility" }
        return "Waiting for Input Monitoring"
    }

    private var modelPrimaryConfig: OnboardingPrimaryConfig {
        switch controller.modelState {
        case .ready:
            return OnboardingPrimaryConfig(title: "Continue", enabled: true, action: advance)
        case .downloading(let progress):
            return OnboardingPrimaryConfig(title: onboardingPhaseLabel(progress.phase), enabled: false) {}
        case .failed:
            return OnboardingPrimaryConfig(title: "Retry model setup", enabled: true) { controller.prepareEngine() }
        case .needsAPIKey:
            return OnboardingPrimaryConfig(title: "Save an API key above", enabled: false) {}
        case .needsDownload, .unknown:
            return OnboardingPrimaryConfig(title: settings.speechModel.isCloud ? "Connect model" : "Download model", enabled: true) { controller.prepareEngine() }
        }
    }

    // MARK: Navigation

    private func advance() {
        guard step < Self.stepCount - 1 else { return }
        withAnimation(Theme.stateSpring) { step += 1 }
    }

    /// Arrow-key path: same gating as the primary button (condition check plus
    /// the finish-on-last-step behavior).
    private func advanceIfReady() {
        if step == Self.stepCount - 1 {
            finish()
        } else {
            guard conditionMet(for: step) else { return }
            advance()
        }
    }

    private func goBack() {
        guard step > 0 else { return }
        withAnimation(Theme.stateSpring) { step -= 1 }
    }

    private func finish() {
        refreshPermissions()
        guard allRequirementsReady else {
            moveToFirstBlockingStep()
            return
        }
        settings.onboardingCompleted = true
        onFinish()
    }

    private func handleStepChange(to newStep: Int) {
        switch newStep {
        case 3:
            // Loading is cheap when the model is already on disk — start it eagerly
            // so the bar fills and the step self-advances without a second tap.
            if settings.speechModel.isDownloaded || (settings.speechModel.isCloud && settings.hasOpenRouterKey) {
                controller.prepareEngine()
            }
            maybeAutoAdvance()
        case 4:
            // The pipeline must be live for the trial dictation to insert into the editor.
            guard allRequirementsReady else {
                moveToFirstBlockingStep()
                return
            }
            controller.activate()
            tryItSucceeded = false
        default:
            maybeAutoAdvance()
        }
    }

    // MARK: Conditions & auto-advance

    private func refreshPermissions() {
        micGranted = Permissions.microphoneGranted
        accessibilityGranted = Permissions.accessibilityGranted
        inputMonitoringGranted = Permissions.inputMonitoringGranted
        handleReadinessChange()
    }

    private func conditionMet(for step: Int) -> Bool {
        switch step {
        case 1: return micGranted
        case 2: return keyboardPermissionsReady
        case 3: return modelReady
        default: return false
        }
    }

    private func handleReadinessChange() {
        if step == 4 && !allRequirementsReady {
            moveToFirstBlockingStep()
            return
        }
        maybeAutoAdvance()
    }

    private func maybeAutoAdvance() {
        guard conditionMet(for: step) else { return }
        scheduleAutoAdvance(from: step)
    }

    private func moveToFirstBlockingStep() {
        guard let blockingStep = firstBlockingStep else { return }
        autoAdvancePending = nil
        guard blockingStep != step else { return }
        withAnimation(Theme.stateSpring) { step = blockingStep }
    }

    /// Wait a beat so the just-granted checkmark is visible, then advance if the
    /// user is still on the same step and the condition still holds.
    private func scheduleAutoAdvance(from: Int) {
        guard autoAdvancePending != from else { return }
        autoAdvancePending = from
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            if autoAdvancePending == from { autoAdvancePending = nil }
            guard step == from, conditionMet(for: from) else { return }
            advance()
        }
    }

    // MARK: Actions

    private func requestMicrophone() {
        micRequestInFlight = true
        Task { @MainActor in
            let granted = await Permissions.requestMicrophone()
            micRequestInFlight = false
            micGranted = granted
            maybeAutoAdvance()
        }
    }

    private func openAccessibility() {
        Permissions.requestAccessibility()
        Permissions.openSettings(pane: .accessibility)
    }

    private func openInputMonitoring() {
        Permissions.requestInputMonitoring()
        Permissions.openSettings(pane: .inputMonitoring)
    }

    private func handleInsertion(_ text: String?) {
        guard step == 4, text != nil else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) {
            tryItSucceeded = true
        }
    }
}

// MARK: - Primary button config

private struct OnboardingPrimaryConfig {
    let title: String
    let enabled: Bool
    let action: () -> Void
}

private func onboardingPhaseLabel(_ phase: ModelDownloadProgress.Phase) -> String {
    switch phase {
    case .checking: return "Checking…"
    case .downloading: return "Downloading…"
    case .compiling: return "Compiling…"
    case .ready: return "Finishing…"
    }
}

// MARK: - Shared step scaffolding

/// Icon badge + title + one paragraph + custom action area — the shape every step
/// (except welcome) takes, per DESIGN.md.
private struct OnboardingStepScaffold<Content: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 20) {
            OnboardingIconBadge(symbol: symbol)
            VStack(spacing: 10) {
                Text(title)
                    .font(Theme.onboardingTitleFont)
                    .tracking(-0.5)
                Text(message)
                    .font(Theme.onboardingBodyFont)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 360)
            }
            content()
        }
        .padding(.horizontal, 44)
    }
}

private struct OnboardingIconBadge: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 24, weight: .regular))
            .foregroundStyle(.primary)
            .frame(width: 56, height: 56)
            .background(.ultraThinMaterial, in: Circle())
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.06)))
    }
}

private struct OnboardingStatusPill: View {
    let granted: Bool
    let grantedText: String
    let pendingText: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dotted")
                .foregroundStyle(granted ? Color.primary : Color.secondary)
            Text(granted ? grantedText : pendingText)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

// MARK: - Step 1 · Welcome

private struct OnboardingWelcomeStep: View {
    let key: DictationKey
    let mode: HotkeyMonitor.Mode

    var body: some View {
        VStack(spacing: 24) {
            AppGlyph(size: 64)
            VStack(spacing: 12) {
                Text("Less typing.\nMore you.")
                    .font(.system(size: 38, weight: .semibold))
                    .tracking(-1.4)
                    .multilineTextAlignment(.center)
                Text("Turn a thought into text, wherever you work.\nPrivate, on-device dictation. Cloud if you choose.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ShortcutGuide(key: key, mode: mode)
        }
        .padding(.horizontal, 40)
    }
}

// MARK: - Step 2 · Microphone

private struct OnboardingMicrophoneStep: View {
    let granted: Bool
    let cloud: Bool

    var body: some View {
        OnboardingStepScaffold(
            symbol: granted ? "checkmark.circle.fill" : "mic",
            title: "Microphone",
            message: granted
                ? "Microphone access is ready. MoDict records only during dictation."
                : "Microphone access is required before MoDict can record. Audio stays on this Mac with local models\(cloud ? "; a selected cloud model sends it to OpenRouter." : ".")"
        ) {
            OnboardingStatusPill(
                granted: granted,
                grantedText: "Microphone ready",
                pendingText: "Microphone required"
            )
        }
    }
}

// MARK: - Step 3 · Accessibility & Input Monitoring

private struct OnboardingPermissionsStep: View {
    let accessibilityGranted: Bool
    let inputMonitoringGranted: Bool
    let key: DictationKey
    let onOpenAccessibility: () -> Void
    let onOpenInputMonitoring: () -> Void

    var body: some View {
        OnboardingStepScaffold(
            symbol: ready ? "checkmark.circle.fill" : "keyboard",
            title: "Keyboard access",
            message: ready
                ? "Keyboard access is ready. MoDict can detect the \(key.inlineName) key and type into your apps."
                : "Both permissions are required before MoDict can detect the \(key.inlineName) key and type into your apps."
        ) {
            VStack(spacing: 12) {
                OnboardingPermissionCard(
                    title: "Accessibility",
                    detail: "Required to type your words into the focused app.",
                    granted: accessibilityGranted,
                    action: onOpenAccessibility
                )
                OnboardingPermissionCard(
                    title: "Input Monitoring",
                    detail: "Required to detect the \(key.inlineName) key.",
                    granted: inputMonitoringGranted,
                    action: onOpenInputMonitoring
                )
            }
            .frame(maxWidth: 380)
            .padding(.top, 4)
        }
    }

    private var ready: Bool {
        accessibilityGranted && inputMonitoringGranted
    }
}

private struct OnboardingPermissionCard: View {
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dotted")
                .font(.system(size: 18))
                .foregroundStyle(granted ? Color.primary : Color.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if granted {
                Text("Ready")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Button("Open Settings", action: action)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
    }
}

// MARK: - Step 4 · Speech model

private struct OnboardingModelStep: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var controller: DictationController
    @State private var pendingCloudSelection: SpeechModel?

    private var model: SpeechModel { settings.speechModel }
    private var state: DictationController.ModelState { controller.modelState }

    private var selection: Binding<SpeechModel> {
        Binding(get: { settings.speechModel }, set: { chosen in
            if chosen.isCloud && chosen != settings.speechModel {
                pendingCloudSelection = chosen
            } else {
                controller.selectModel(chosen)
            }
        })
    }

    var body: some View {
        ScrollView {
            OnboardingStepScaffold(
                symbol: isReady ? "checkmark.circle.fill" : (model.isCloud ? "cloud" : "arrow.down.circle"),
                title: "Speech model",
                message: isReady
                    ? "\(model.displayName) is ready for \(model.isCloud ? "cloud" : "on-device") dictation."
                    : "Choose a model before dictation. \(model.displayName) · \(model.detail)\(model.isCloud ? "" : " · ≈ \(sizeText)")."
            ) {
                VStack(spacing: 10) {
                    Picker("Model", selection: selection) {
                        ForEach(SpeechModel.localModels) { item in
                            Text(item.displayName).tag(item)
                        }
                        ForEach(SpeechModel.cloudModels) { item in
                            Text("\(item.displayName) · Cloud *").tag(item)
                        }
                    }
                    .frame(width: 340)
                    .disabled(controller.isManagingModel)
                    statusView.frame(height: 56)
                    if model.isCloud {
                        CloudPrivacyNotice()
                            .frame(maxWidth: 380)
                        OpenRouterKeySection(settings: settings, controller: controller)
                            .frame(maxWidth: 380)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        }
        .confirmationDialog(
            "Use \(pendingCloudSelection?.displayName ?? "cloud model")?",
            isPresented: Binding(
                get: { pendingCloudSelection != nil },
                set: { if !$0 { pendingCloudSelection = nil } }
            ),
            presenting: pendingCloudSelection
        ) { selected in
            Button("Use cloud model") {
                controller.selectModel(selected)
                pendingCloudSelection = nil
            }
            Button("Cancel", role: .cancel) { pendingCloudSelection = nil }
        } message: { _ in
            Text("Each recording will be sent to OpenRouter and a model provider. Providers may retain or use data to improve models. API usage may cost money.")
        }
    }

    private var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    private var sizeText: String {
        ByteCountFormatter.string(fromByteCount: model.approximateDownloadBytes, countStyle: .file)
    }

    @ViewBuilder
    private var statusView: some View {
        switch state {
        case .downloading(let progress):
            VStack(spacing: 8) {
                ProgressView(value: progress.fraction)
                    .progressViewStyle(.linear)
                    .tint(.primary)
                    .frame(width: 300)
                Text(progressLabel(progress))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        case .ready:
            OnboardingStatusPill(granted: true, grantedText: "Speech model ready", pendingText: "")
        case .needsAPIKey:
            Text("Add your OpenRouter API key below to continue.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        case .failed(let message):
            VStack(spacing: 6) {
                Label("Model not ready", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.red)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: 300)
            }
        case .needsDownload, .unknown:
            Text(model.isCloud ? "Checking cloud model…" : "One download, then you can dictate offline.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
    }

    private func progressLabel(_ progress: ModelDownloadProgress) -> String {
        switch progress.phase {
        case .checking: return "Checking…"
        case .downloading: return "Downloading… \(Int((progress.fraction * 100).rounded()))%"
        case .compiling: return "Compiling…"
        case .ready: return "Finishing…"
        }
    }
}

// MARK: - Step 5 · Try it

private struct OnboardingTryItStep: View {
    @Binding var text: String
    let succeeded: Bool
    let ready: Bool
    let key: DictationKey
    let mode: HotkeyMonitor.Mode

    var body: some View {
        VStack(spacing: 20) {
            if !ready {
                OnboardingIconBadge(symbol: "exclamationmark.circle")
                VStack(spacing: 10) {
                    Text("Setup incomplete")
                        .font(Theme.onboardingTitleFont)
                        .tracking(-0.5)
                    Text("MoDict needs microphone access, keyboard access, and the speech model before dictation can start.")
                        .font(Theme.onboardingBodyFont)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }
            } else if succeeded {
                OnboardingSuccessBadge()
                VStack(spacing: 10) {
                    Text("That's it.")
                        .font(Theme.onboardingTitleFont)
                        .tracking(-0.5)
                    Text("MoDict lives in your menu bar.")
                        .font(Theme.onboardingBodyFont)
                        .foregroundStyle(.secondary)
                }
            } else {
                OnboardingIconBadge(symbol: "text.cursor")
                VStack(spacing: 10) {
                    Text("Try it")
                        .font(Theme.onboardingTitleFont)
                        .tracking(-0.5)
                    Text(DictationGesture.instruction(key: key, mode: mode))
                        .font(Theme.onboardingBodyFont)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }
            }
            if ready {
                OnboardingTryEditor(text: $text)
            }
        }
        .padding(.horizontal, 44)
    }
}

private struct OnboardingTryEditor: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        TextEditor(text: $text)
            .focused($focused)
            .onAppear { focused = true }
            .accessibilityLabel("Try dictation here")
            .font(.system(size: 14))
            .scrollContentBackground(.hidden)
            .padding(10)
            .frame(width: 360, height: 120)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Your words will appear here…")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 18)
                        .allowsHitTesting(false)
                }
            }
    }
}

private struct OnboardingSuccessBadge: View {
    @State private var shown = false

    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 24, weight: .semibold))
            .foregroundStyle(.primary)
            .scaleEffect(shown ? 1 : 0.4)
            .opacity(shown ? 1 : 0)
            .frame(width: 56, height: 56)
            .background(.ultraThinMaterial, in: Circle())
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.06)))
            .onAppear {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) { shown = true }
            }
    }
}
