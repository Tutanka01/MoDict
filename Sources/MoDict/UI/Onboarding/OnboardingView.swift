import SwiftUI
import Combine

/// Five-step first-run flow: welcome → microphone → keyboard permissions → speech
/// model → live try-it. Steps advance automatically the moment their condition is
/// met (permission granted, model ready) and are otherwise skippable. The view owns
/// the flow; `onFinish` hands window dismissal back to `OnboardingController`.
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
        .onChange(of: controller.modelState) { _, _ in maybeAutoAdvance() }
        .onChange(of: controller.lastInsertedText) { _, newValue in handleInsertion(newValue) }
        .onKeyPress(.leftArrow) { goBack(); return .handled }
        .onKeyPress(.rightArrow) { skipForward(); return .handled }
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
            if canSkip {
                Button("Skip", action: skipForward)
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
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
            OnboardingWelcomeStep()
        case 1:
            OnboardingMicrophoneStep(granted: micGranted)
        case 2:
            OnboardingPermissionsStep(
                accessibilityGranted: accessibilityGranted,
                inputMonitoringGranted: inputMonitoringGranted,
                onOpenAccessibility: openAccessibility,
                onOpenInputMonitoring: openInputMonitoring
            )
        case 3:
            OnboardingModelStep(state: controller.modelState)
        default:
            OnboardingTryItStep(text: $tryText, succeeded: tryItSucceeded)
        }
    }

    private var canSkip: Bool { (1...3).contains(step) }

    // MARK: Primary action per step

    private var primaryConfig: OnboardingPrimaryConfig {
        switch step {
        case 0:
            return OnboardingPrimaryConfig(title: "Get started", enabled: true, action: advance)
        case 1:
            if micGranted {
                return OnboardingPrimaryConfig(title: "Continue", enabled: true, action: advance)
            } else if Permissions.microphoneDenied {
                return OnboardingPrimaryConfig(title: "Open Settings", enabled: true) {
                    Permissions.openSettings(pane: .microphone)
                }
            } else {
                return OnboardingPrimaryConfig(title: "Allow microphone", enabled: !micRequestInFlight, action: requestMicrophone)
            }
        case 2:
            return OnboardingPrimaryConfig(title: "Continue", enabled: true, action: advance)
        case 3:
            return modelPrimaryConfig
        default:
            return OnboardingPrimaryConfig(title: "Start dictating", enabled: true, action: finish)
        }
    }

    private var modelPrimaryConfig: OnboardingPrimaryConfig {
        switch controller.modelState {
        case .ready:
            return OnboardingPrimaryConfig(title: "Continue", enabled: true, action: advance)
        case .downloading(let progress):
            return OnboardingPrimaryConfig(title: onboardingPhaseLabel(progress.phase), enabled: false) {}
        case .failed:
            return OnboardingPrimaryConfig(title: "Retry", enabled: true) { controller.prepareEngine() }
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

    private func skipForward() {
        if step == 0 || canSkip { advance() }
    }

    private func finish() {
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
            controller.activate()
            tryItSucceeded = controller.lastInsertedText != nil
        default:
            maybeAutoAdvance()
        }
    }

    // MARK: Conditions & auto-advance

    private func refreshPermissions() {
        micGranted = Permissions.microphoneGranted
        accessibilityGranted = Permissions.accessibilityGranted
        inputMonitoringGranted = Permissions.inputMonitoringGranted
        maybeAutoAdvance()
    }

    private func conditionMet(for step: Int) -> Bool {
        switch step {
        case 1: return micGranted
        case 2: return accessibilityGranted && inputMonitoringGranted
        case 3: return controller.modelState == .ready
        default: return false
        }
    }

    private func maybeAutoAdvance() {
        guard conditionMet(for: step) else { return }
        scheduleAutoAdvance(from: step)
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
    var body: some View {
        VStack(spacing: 22) {
            OnboardingAppGlyph()
            VStack(spacing: 10) {
                Text("Dictate anywhere.")
                    .font(Theme.onboardingTitleFont)
                    .tracking(-0.5)
                Text("Hold the right ⌘ key, speak, release. Your words appear wherever your cursor is. 100% on-device.")
                    .font(Theme.onboardingBodyFont)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 360)
            }
            OnboardingKeycap()
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

/// A small right-⌘ keycap that gently presses in a loop.
private struct OnboardingKeycap: View {
    @State private var pressed = false

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: "command")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 46, height: 42)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
                .offset(y: pressed ? 3 : 0)
                .shadow(color: Theme.hudShadow, radius: pressed ? 2 : 6, y: pressed ? 1 : 4)
            Text("right ⌘")
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
            message: "MoDict listens only while you hold the key. Audio is transcribed on your Mac and never leaves it."
        ) {
            OnboardingStatusPill(
                granted: granted,
                grantedText: "Microphone access granted",
                pendingText: "Microphone access needed"
            )
        }
    }
}

// MARK: - Step 3 · Accessibility & Input Monitoring

private struct OnboardingPermissionsStep: View {
    let accessibilityGranted: Bool
    let inputMonitoringGranted: Bool
    let onOpenAccessibility: () -> Void
    let onOpenInputMonitoring: () -> Void

    var body: some View {
        OnboardingStepScaffold(
            symbol: "keyboard",
            title: "Keyboard access",
            message: "To detect the right ⌘ key and type text into your apps. MoDict never logs your keystrokes."
        ) {
            VStack(spacing: 12) {
                OnboardingPermissionCard(
                    title: "Accessibility",
                    detail: "Types your words into the focused app.",
                    granted: accessibilityGranted,
                    action: onOpenAccessibility
                )
                OnboardingPermissionCard(
                    title: "Input Monitoring",
                    detail: "Detects the right ⌘ key.",
                    granted: inputMonitoringGranted,
                    action: onOpenInputMonitoring
                )
            }
            .frame(maxWidth: 380)
            .padding(.top, 4)
        }
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
                Text("Granted")
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
            message: "Parakeet v3 · 25 languages · runs on the Neural Engine · ~480 MB."
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
            OnboardingStatusPill(granted: true, grantedText: "Model ready", pendingText: "")
        case .failed(let message):
            VStack(spacing: 6) {
                Label("Download failed", systemImage: "exclamationmark.triangle")
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
            Text("One-time download. You can keep using your Mac while it finishes.")
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

    var body: some View {
        VStack(spacing: 20) {
            if succeeded {
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
                    Text("Click below, hold the right ⌘ key and say something.")
                        .font(Theme.onboardingBodyFont)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }
            }
            OnboardingTryEditor(text: $text)
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
