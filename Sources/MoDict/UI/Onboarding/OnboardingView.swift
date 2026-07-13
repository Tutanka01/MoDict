import SwiftUI
import Combine

/// Five-step first-run flow: welcome → microphone → keyboard permissions → speech
/// model → live try-it. Steps advance automatically the moment their condition is
/// met (permission granted, model ready). Required permissions and the model are
/// never skippable; `onFinish` hands window dismissal back to
/// `OnboardingController`.
struct OnboardingView: View {

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
        .onKeyPress(.rightArrow) { continueIfReady(); return .handled }
    }

    // MARK: Chrome

    private var topBar: some View {
        HStack {
            if step > 0 {
                Button(action: goBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("[", modifiers: .command)
                .help("Back")
            }
            Spacer()
        }
        .frame(height: 44)
        .padding(.horizontal, 22)
    }

    private var footer: some View {
        VStack(spacing: 18) {
            OnboardingProgressDots(count: Self.stepCount, current: step)
            primaryButton
        }
        .padding(.horizontal, 40)
        .padding(.bottom, 30)
        .padding(.top, 8)
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
            OnboardingWelcomeStep(key: settings.dictationKey)
        case 1:
            OnboardingMicrophoneStep(granted: micGranted)
        case 2:
            OnboardingPermissionsStep(
                accessibilityGranted: accessibilityGranted,
                inputMonitoringGranted: inputMonitoringGranted,
                key: settings.dictationKey,
                onOpenAccessibility: openAccessibility,
                onOpenInputMonitoring: openInputMonitoring
            )
        case 3:
            OnboardingModelStep(state: controller.modelState)
        default:
            OnboardingTryItStep(text: $tryText, succeeded: tryItSucceeded,
                                ready: allRequirementsReady, key: settings.dictationKey)
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
            return OnboardingPrimaryConfig(title: "Retry download", enabled: true) { controller.prepareEngine() }
        case .needsDownload, .unknown:
            return OnboardingPrimaryConfig(title: "Download model", enabled: true) { controller.prepareEngine() }
        }
    }

    // MARK: Navigation

    private func advance() {
        guard step < Self.stepCount - 1 else { return }
        withAnimation(Theme.stateSpring) { step += 1 }
    }

    private func goBack() {
        guard step > 0 else { return }
        withAnimation(Theme.stateSpring) { step -= 1 }
    }

    private func continueIfReady() {
        switch step {
        case 0:
            advance()
        case 1...3:
            guard conditionMet(for: step) else { return }
            advance()
        case 4:
            finish()
        default:
            break
        }
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
            if FluidAudioEngine.modelsExistOnDisk() {
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

private struct OnboardingProgressDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(index == current ? Color.primary : Color.secondary.opacity(0.3))
                    .frame(width: index == current ? 7 : 6, height: index == current ? 7 : 6)
            }
        }
        .animation(Theme.stateSpring, value: current)
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

    var body: some View {
        VStack(spacing: 22) {
            OnboardingAppGlyph()
            VStack(spacing: 10) {
                Text("Dictate anywhere.")
                    .font(Theme.onboardingTitleFont)
                    .tracking(-0.5)
                Text("Hold the \(key.inlineName) key, speak, release. Your words appear wherever your cursor is. 100% on-device.")
                    .font(Theme.onboardingBodyFont)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 360)
            }
            OnboardingKeycap(key: key)
                .padding(.top, 4)
        }
        .padding(.horizontal, 44)
    }
}

/// The app icon rendered in-app: near-black squircle, five white waveform bars,
/// center tallest (see DESIGN.md · App icon).
private struct OnboardingAppGlyph: View {
    private let heights: [CGFloat] = [14, 22, 32, 22, 14]

    var body: some View {
        HStack(spacing: 5) {
            ForEach(heights.indices, id: \.self) { index in
                Capsule()
                    .fill(.white)
                    .frame(width: 5, height: heights[index])
            }
        }
        .frame(width: 74, height: 74)
        .background(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .fill(Color(red: 0.078, green: 0.078, blue: 0.078))
        )
        .shadow(color: Theme.hudShadow, radius: 14, y: 6)
    }
}

/// A small keycap of the chosen dictation key that gently presses in a loop.
private struct OnboardingKeycap: View {
    let key: DictationKey
    @State private var pressed = false

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: key.keycapSymbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 46, height: 42)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
                .offset(y: pressed ? 3 : 0)
                .shadow(color: Theme.hudShadow, radius: pressed ? 2 : 6, y: pressed ? 1 : 4)
            Text(key.inlineName)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true)) {
                pressed = true
            }
        }
    }
}

// MARK: - Step 2 · Microphone

private struct OnboardingMicrophoneStep: View {
    let granted: Bool

    var body: some View {
        OnboardingStepScaffold(
            symbol: granted ? "checkmark.circle.fill" : "mic",
            title: "Microphone",
            message: granted
                ? "Microphone access is ready. MoDict listens only while you hold the key."
                : "Microphone access is required before MoDict can record. Audio is transcribed on your Mac and never leaves it."
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
    let state: DictationController.ModelState

    var body: some View {
        OnboardingStepScaffold(
            symbol: isReady ? "checkmark.circle.fill" : "arrow.down.circle",
            title: "Speech model",
            message: isReady
                ? "Parakeet v3 is ready for on-device dictation."
                : "The speech model is required before dictation can start. Parakeet v3 · 25 languages · ~480 MB."
        ) {
            statusView
                .frame(height: 60)
        }
    }

    private var isReady: Bool {
        if case .ready = state { return true }
        return false
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
            Text("Required one-time download. Setup stays locked until the model is ready.")
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
                    Text("Click below, hold the \(key.inlineName) key and say something. Watch your words appear as you speak.")
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

    var body: some View {
        TextEditor(text: $text)
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
