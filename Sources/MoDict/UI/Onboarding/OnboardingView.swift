import SwiftUI
import Combine

/// Five-step first-run flow: welcome → speech model → microphone → keyboard
/// permissions → live try-it. The model download starts on the second step and
/// keeps running behind the permission steps, so setup never waits on it: a
/// progress strip follows the user, and "Try it" can be finished in the
/// background if the download is still going. Permissions are never skippable.
/// Steps advance by themselves the moment their condition is met; `onFinish`
/// hands window dismissal back to `OnboardingController`.
struct OnboardingView: View {

    static let windowSize = CGSize(width: 520, height: 640)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let onFinish: () -> Void
    @ObservedObject private var settings: SettingsStore
    @ObservedObject private var controller: DictationController

    init(app: AppModel, startingAt step: OnboardingStep = .welcome, onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        self._settings = ObservedObject(wrappedValue: app.settings)
        self._controller = ObservedObject(wrappedValue: app.controller)
        self._step = State(initialValue: step)
    }

    @State private var step: OnboardingStep
    @State private var micGranted = false
    @State private var micDenied = false
    @State private var accessibilityGranted = false
    @State private var inputMonitoringGranted = false
    @State private var micRequestInFlight = false
    @State private var tryItSucceeded = false
    @State private var tryText = ""
    /// The step an auto-advance is currently scheduled for, so we don't stack them.
    @State private var autoAdvancePending: OnboardingStep?
    /// Steps the user came back to or chose something on: they stay put until the
    /// user moves on, however satisfied their condition already is.
    @State private var autoAdvanceSuppressed: Set<OnboardingStep> = []
    @State private var pipelineStarted = false
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
            if showsDock {
                OnboardingDownloadDock(model: settings.speechModel, state: controller.modelState) {
                    controller.prepareEngine()
                }
                .padding(.horizontal, 40)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            footer
        }
        .frame(width: Self.windowSize.width, height: Self.windowSize.height)
        .animation(Theme.stateSpring, value: showsDock)
        .onAppear {
            refreshPermissions()
            enter(step)
        }
        .onReceive(pollTimer) { _ in refreshPermissions() }
        .onChange(of: step) { _, newStep in enter(newStep) }
        .onChange(of: controller.modelState) { _, _ in handleReadinessChange() }
        .onChange(of: controller.lastInsertedText) { _, newValue in handleInsertion(newValue) }
        .onKeyPress(.leftArrow) {
            // The editor on the last step owns the arrow keys.
            guard step != .tryIt else { return .ignored }
            goBack()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            guard step != .tryIt else { return .ignored }
            advanceIfReady()
            return .handled
        }
        .transaction { if reduceMotion { $0.animation = nil } }
    }

    // MARK: Chrome

    private var topBar: some View {
        VStack(spacing: 24) {
            HStack(spacing: 10) {
                if step != .welcome {
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
                Text("SETUP  ·  \(step.rawValue + 1) OF \(OnboardingStep.allCases.count)")
                    .font(.system(size: 10, weight: .medium)).tracking(1)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                ForEach(OnboardingStep.allCases, id: \.self) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        Capsule().fill(.primary.opacity(item.rawValue <= step.rawValue ? 0.8 : 0.1)).frame(height: 3)
                        Text(item.title)
                            .font(.system(size: 10, weight: item == step ? .semibold : .regular))
                            .foregroundStyle(item == step ? .primary : .secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Setup step \(step.rawValue + 1) of \(OnboardingStep.allCases.count), \(step.title)")
        }
        .padding(.horizontal, 32)
        .padding(.top, 24)
        .padding(.bottom, 12)
    }

    private var footer: some View {
        VStack(spacing: 12) {
            primaryButton
            Text(step == .welcome ? "Created by Mohamad El Akhal" : "Your settings can be changed at any time.")
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
        }
        .buttonStyle(OnboardingPrimaryButtonStyle())
        .disabled(!config.enabled)
        .keyboardShortcut(.defaultAction)
    }

    /// The model keeps arriving behind the permission steps; this strip keeps it
    /// in view there. The model and last steps report it in place.
    private var showsDock: Bool {
        (step == .microphone || step == .access)
            && OnboardingModelStatus.title(model: settings.speechModel, state: controller.modelState) != nil
    }

    // MARK: Steps

    @ViewBuilder
    private func stepView(for step: OnboardingStep) -> some View {
        switch step {
        case .welcome:
            OnboardingWelcomeStep(key: settings.dictationKey, mode: settings.hotkeyMode)
        case .model:
            OnboardingModelStep(settings: settings, controller: controller) {
                autoAdvanceSuppressed.insert(.model)
            }
        case .microphone:
            OnboardingMicrophoneStep(granted: micGranted, denied: micDenied, cloud: settings.speechModel.isCloud)
        case .access:
            OnboardingPermissionsStep(
                accessibilityGranted: accessibilityGranted,
                inputMonitoringGranted: inputMonitoringGranted,
                key: settings.dictationKey,
                onOpenAccessibility: openAccessibility,
                onOpenInputMonitoring: openInputMonitoring
            )
        case .tryIt:
            OnboardingTryItStep(
                text: $tryText,
                succeeded: tryItSucceeded,
                ready: readiness.dictationReady,
                model: settings.speechModel,
                modelState: controller.modelState,
                key: settings.dictationKey,
                mode: settings.hotkeyMode
            )
        }
    }

    private var readiness: OnboardingReadiness {
        OnboardingReadiness(
            microphone: micGranted,
            accessibility: accessibilityGranted,
            inputMonitoring: inputMonitoringGranted,
            model: controller.modelState
        )
    }

    // MARK: Primary action per step

    private var primaryConfig: OnboardingPrimaryConfig {
        switch step {
        case .welcome:
            return OnboardingPrimaryConfig(title: "Get started", enabled: true, action: advance)
        case .model:
            return modelPrimaryConfig
        case .microphone:
            if micGranted {
                return OnboardingPrimaryConfig(title: "Continue", enabled: true, action: advance)
            } else if micRequestInFlight {
                return OnboardingPrimaryConfig(title: "Waiting for macOS…", enabled: false) {}
            } else if micDenied {
                return OnboardingPrimaryConfig(title: "Open Microphone Settings", enabled: true) {
                    Permissions.openSettings(pane: .microphone)
                }
            } else {
                return OnboardingPrimaryConfig(title: "Allow microphone", enabled: true, action: requestMicrophone)
            }
        case .access:
            if readiness.keyboard {
                return OnboardingPrimaryConfig(title: "Continue", enabled: true, action: advance)
            } else if !accessibilityGranted {
                return OnboardingPrimaryConfig(title: "Open Accessibility Settings", enabled: true, action: openAccessibility)
            } else {
                return OnboardingPrimaryConfig(title: "Open Input Monitoring Settings", enabled: true, action: openInputMonitoring)
            }
        case .tryIt:
            if readiness.dictationReady {
                return OnboardingPrimaryConfig(title: "Start dictating", enabled: true, action: finish)
            } else if readiness.canFinish {
                return OnboardingPrimaryConfig(title: "Finish in background", enabled: true, action: finish)
            } else {
                return OnboardingPrimaryConfig(title: "Review setup", enabled: true, action: moveToFirstBlockingStep)
            }
        }
    }

    /// Choosing the model is the only thing setup asks for here: the download it
    /// starts runs in the background, so the step moves on at once.
    private var modelPrimaryConfig: OnboardingPrimaryConfig {
        let model = settings.speechModel
        switch controller.modelState {
        case .ready, .downloading:
            return OnboardingPrimaryConfig(title: "Continue", enabled: true, action: advance)
        case .failed:
            return OnboardingPrimaryConfig(title: "Try again and continue", enabled: true) {
                controller.prepareEngine()
                advance()
            }
        case .needsAPIKey:
            return OnboardingPrimaryConfig(title: "Save an API key above", enabled: false) {}
        case .needsDownload, .unknown:
            let title = model.isCloud ? "Connect and continue"
                : (model.isDownloaded ? "Continue" : "Download and continue")
            return OnboardingPrimaryConfig(title: title, enabled: true) {
                controller.prepareEngine()
                advance()
            }
        }
    }

    // MARK: Navigation

    private func advance() {
        guard let next = step.next else { return }
        autoAdvanceSuppressed.remove(step)
        autoAdvancePending = nil
        withAnimation(Theme.stateSpring) { step = next }
    }

    /// Arrow-key path: same gating as the primary button.
    private func advanceIfReady() {
        guard readiness.isMet(step) else { return }
        advance()
    }

    private func goBack() {
        guard let previous = step.previous else { return }
        autoAdvanceSuppressed.insert(previous)
        autoAdvancePending = nil
        withAnimation(Theme.stateSpring) { step = previous }
    }

    private func finish() {
        refreshPermissions()
        guard readiness.canFinish else {
            moveToFirstBlockingStep()
            return
        }
        settings.onboardingCompleted = true
        onFinish()
    }

    private func enter(_ newStep: OnboardingStep) {
        switch newStep {
        case .model:
            // Loading is cheap when the model is already on disk — start it eagerly
            // so the step self-advances once it is ready.
            if settings.speechModel.isDownloaded || (settings.speechModel.isCloud && settings.hasOpenRouterKey) {
                controller.prepareEngine()
            }
            maybeAutoAdvance()
        case .tryIt:
            guard readiness.canFinish else {
                moveToFirstBlockingStep()
                return
            }
            tryItSucceeded = false
            startPipelineIfReady()
        default:
            maybeAutoAdvance()
        }
    }

    /// The pipeline must be live for the trial dictation to insert into the editor.
    private func startPipelineIfReady() {
        guard step == .tryIt, readiness.dictationReady, !pipelineStarted else { return }
        pipelineStarted = true
        controller.activate()
    }

    // MARK: Conditions & auto-advance

    private func refreshPermissions() {
        micGranted = Permissions.microphoneGranted
        micDenied = Permissions.microphoneDenied
        accessibilityGranted = Permissions.accessibilityGranted
        inputMonitoringGranted = Permissions.inputMonitoringGranted
        handleReadinessChange()
    }

    private func handleReadinessChange() {
        if step == .tryIt {
            guard readiness.canFinish else {
                moveToFirstBlockingStep()
                return
            }
            startPipelineIfReady()
            return
        }
        maybeAutoAdvance()
    }

    private func maybeAutoAdvance() {
        guard readiness.isMet(step), !autoAdvanceSuppressed.contains(step) else { return }
        scheduleAutoAdvance(from: step)
    }

    private func moveToFirstBlockingStep() {
        guard let blockingStep = readiness.firstBlockingStep else { return }
        autoAdvancePending = nil
        guard blockingStep != step else { return }
        autoAdvanceSuppressed.remove(blockingStep)
        withAnimation(Theme.stateSpring) { step = blockingStep }
    }

    /// Wait a beat so the just-granted checkmark is visible, then advance if the
    /// user is still on the same step and the condition still holds.
    private func scheduleAutoAdvance(from: OnboardingStep) {
        guard autoAdvancePending != from else { return }
        autoAdvancePending = from
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            if autoAdvancePending == from { autoAdvancePending = nil }
            guard step == from, readiness.isMet(from), !autoAdvanceSuppressed.contains(from) else { return }
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
            micDenied = Permissions.microphoneDenied
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
        guard step == .tryIt, text != nil else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) {
            tryItSucceeded = true
        }
    }
}

// MARK: - Primary button

private struct OnboardingPrimaryConfig {
    let title: String
    let enabled: Bool
    let action: () -> Void
}

/// A solid, full-width button drawn with explicit colors. `.borderedProminent`
/// with `.tint(.primary)` let macOS pick the label color from a dynamic tint and
/// produced a black button with black text; here the fill is `.primary` and the
/// label is the window's own background, so they always contrast.
struct OnboardingPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PrimaryButtonBody(configuration: configuration)
    }

    private struct PrimaryButtonBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isEnabled ? Color(nsColor: .windowBackgroundColor) : Color.secondary)
                .frame(maxWidth: .infinity, minHeight: 42)
                .background(fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }

        private var fill: Color {
            guard isEnabled else { return Color.primary.opacity(0.1) }
            if configuration.isPressed { return Color.primary.opacity(0.7) }
            return Color.primary.opacity(hovering ? 0.84 : 0.92)
        }
    }
}
