import SwiftUI

// Step bodies and shared pieces for `OnboardingView`, which owns the flow, the
// gating and the primary action. Everything here renders values it is handed.

// MARK: - Shared scaffolding

/// Icon badge + title + one paragraph — the shape every step (except welcome) takes.
struct OnboardingStepHeader: View {
    let symbol: String
    let title: String
    let message: String

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
        }
    }
}

/// Header plus a custom action area.
struct OnboardingStepScaffold<Content: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 20) {
            OnboardingStepHeader(symbol: symbol, title: title, message: message)
            content()
        }
        .padding(.horizontal, 44)
    }
}

struct OnboardingIconBadge: View {
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

struct OnboardingStatusPill: View {
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

/// A linear bar with its caption; indeterminate when bytes are not moving yet
/// (checking, compiling).
struct OnboardingDownloadBar: View {
    let title: String
    let fraction: Double?

    var body: some View {
        VStack(spacing: 8) {
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .tint(.primary)
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .frame(maxWidth: 300)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(fraction.map { "\(Int(($0 * 100).rounded())) percent" } ?? "In progress")
    }
}

/// The model's progress while the user is on another step: the download keeps
/// running behind the permission steps and this strip keeps it in view.
struct OnboardingDownloadDock: View {
    let model: SpeechModel
    let state: DictationController.ModelState
    let onRetry: () -> Void

    var body: some View {
        if let title = OnboardingModelStatus.title(model: model, state: state) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 17))
                    .foregroundStyle(isFailed ? Color.red : Color.primary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                    if case .downloading = state {
                        ProgressView(value: OnboardingModelStatus.fraction(for: state))
                            .progressViewStyle(.linear)
                            .tint(.primary)
                    }
                    if case .failed(let message) = state {
                        Text(message)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if isFailed {
                    Button("Retry", action: onRetry)
                        .controlSize(.small)
                }
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
            .accessibilityElement(children: isFailed ? .contain : .combine)
            .accessibilityLabel(title)
        }
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private var symbol: String {
        switch state {
        case .ready: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle"
        default: "arrow.down.circle"
        }
    }
}

// MARK: - Welcome

struct OnboardingWelcomeStep: View {
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

// MARK: - Speech model

struct OnboardingModelStep: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var controller: DictationController
    /// The user picked a model here, so the step must not move on by itself.
    let onChoose: () -> Void
    @State private var pendingCloudSelection: SpeechModel?
    @State private var cloudExpanded: Bool

    init(settings: SettingsStore, controller: DictationController, onChoose: @escaping () -> Void) {
        self.settings = settings
        self.controller = controller
        self.onChoose = onChoose
        self._cloudExpanded = State(initialValue: settings.speechModel.isCloud)
    }

    private var model: SpeechModel { settings.speechModel }
    private var state: DictationController.ModelState { controller.modelState }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                OnboardingStepHeader(symbol: symbol, title: "Speech model", message: message)
                VStack(spacing: 8) {
                    ForEach(SpeechModel.localModels) { item in
                        OnboardingModelRow(
                            model: item,
                            selected: item == model,
                            recommended: item == .parakeetV3,
                            trailing: trailingText(for: item),
                            locked: controller.isManagingModel
                        ) { choose(item) }
                    }
                    cloudDisclosure
                }
                .frame(maxWidth: 400)
                statusView
                if model.isCloud {
                    CloudPrivacyNotice().frame(maxWidth: 400)
                    OpenRouterKeySection(settings: settings, controller: controller)
                        .frame(maxWidth: 400)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 44)
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

    private var isReady: Bool { state == .ready }

    private var symbol: String {
        isReady ? "checkmark.circle.fill" : (model.isCloud ? "cloud" : "arrow.down.circle")
    }

    private var message: String {
        if isReady {
            return "\(model.displayName) is ready for \(model.isCloud ? "cloud" : "on-device") dictation."
        }
        if model.isCloud {
            return "Recordings are sent to OpenRouter for transcription. You choose the model and bring your own key."
        }
        return "Dictation runs on this Mac. The download continues in the background while you finish setup."
    }

    private func choose(_ chosen: SpeechModel) {
        guard chosen != model, !controller.isManagingModel else { return }
        onChoose()
        if chosen.isCloud {
            pendingCloudSelection = chosen
        } else {
            controller.selectModel(chosen)
        }
    }

    private func trailingText(for item: SpeechModel) -> String {
        if item.isCloud { return "Cloud" }
        switch controller.modelState(for: item) {
        case .ready: return "On this Mac"
        case .downloading(let progress) where progress.phase == .downloading:
            return "\(Int((progress.fraction * 100).rounded()))%"
        default:
            return "≈ " + ByteCountFormatter.string(fromByteCount: item.approximateDownloadBytes, countStyle: .file)
        }
    }

    private var cloudDisclosure: some View {
        VStack(spacing: 8) {
            Button {
                withAnimation(Theme.stateSpring) { cloudExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "cloud")
                        .font(.system(size: 12))
                    Text("Use a cloud model instead")
                        .font(.system(size: 12))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(cloudExpanded ? 90 : 0))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.top, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cloud models")
            .accessibilityValue(cloudExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Shows transcription models that send audio to OpenRouter")

            if cloudExpanded {
                ForEach(SpeechModel.cloudModels) { item in
                    OnboardingModelRow(
                        model: item,
                        selected: item == model,
                        recommended: false,
                        trailing: trailingText(for: item),
                        locked: controller.isManagingModel
                    ) { choose(item) }
                }
            }
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch state {
        case .downloading:
            OnboardingDownloadBar(
                title: OnboardingModelStatus.title(model: model, state: state) ?? "Working…",
                fraction: OnboardingModelStatus.fraction(for: state)
            )
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
        case .needsDownload:
            Text("Downloads once, then works offline.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        case .unknown:
            EmptyView()
        }
    }
}

struct OnboardingModelRow: View {
    let model: SpeechModel
    let selected: Bool
    let recommended: Bool
    let trailing: String
    /// A download or load is running: the choice is frozen until it ends.
    let locked: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(model.displayName)
                            .font(.system(size: 13, weight: .medium))
                        if recommended {
                            Text("RECOMMENDED")
                                .font(.system(size: 8.5, weight: .semibold))
                                .tracking(0.6)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.primary.opacity(0.07), in: Capsule())
                        }
                    }
                    Text(model.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(trailing)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(selected ? Color.primary.opacity(0.06) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(selected ? 0.4 : 0.06), lineWidth: selected ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(locked && !selected)
        .opacity(locked && !selected ? 0.5 : 1)
        .accessibilityLabel("\(model.displayName), \(model.detail), \(trailing)")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

// MARK: - Microphone

struct OnboardingMicrophoneStep: View {
    let granted: Bool
    let denied: Bool
    let cloud: Bool

    var body: some View {
        OnboardingStepScaffold(
            symbol: granted ? "checkmark.circle.fill" : (denied ? "mic.slash" : "mic"),
            title: "Microphone",
            message: message
        ) {
            OnboardingStatusPill(
                granted: granted,
                grantedText: "Microphone ready",
                pendingText: denied ? "Microphone is turned off" : "Microphone required"
            )
        }
    }

    private var message: String {
        if granted { return "Microphone access is ready. MoDict records only during dictation." }
        if denied {
            return "Microphone access is off for MoDict. Open System Settings, switch MoDict on under Microphone, then come back."
        }
        return "Microphone access is required before MoDict can record. Audio stays on this Mac with local models\(cloud ? "; a selected cloud model sends it to OpenRouter." : ".")"
    }
}

// MARK: - Accessibility & Input Monitoring

struct OnboardingPermissionsStep: View {
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
                if !ready {
                    Text("Switch MoDict on in each list. This window updates by itself.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 380)
            .padding(.top, 4)
        }
    }

    private var ready: Bool {
        accessibilityGranted && inputMonitoringGranted
    }
}

struct OnboardingPermissionCard: View {
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

// MARK: - Try it

struct OnboardingTryItStep: View {
    @Binding var text: String
    let succeeded: Bool
    /// Microphone, keyboard access and the model are all in place.
    let ready: Bool
    let model: SpeechModel
    let modelState: DictationController.ModelState
    let key: DictationKey
    let mode: HotkeyMonitor.Mode

    var body: some View {
        VStack(spacing: 20) {
            if !ready {
                OnboardingStepHeader(
                    symbol: "arrow.down.circle",
                    title: "Almost there",
                    message: "\(model.displayName) is still getting ready. You can finish setup now — MoDict will be ready in your menu bar as soon as it is."
                )
                if let title = OnboardingModelStatus.title(model: model, state: modelState) {
                    OnboardingDownloadBar(title: title, fraction: OnboardingModelStatus.fraction(for: modelState))
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
                OnboardingStepHeader(
                    symbol: "text.cursor",
                    title: "Try it",
                    message: DictationGesture.instruction(key: key, mode: mode)
                )
            }
            if ready {
                OnboardingTryEditor(text: $text)
            }
        }
        .padding(.horizontal, 44)
    }
}

struct OnboardingTryEditor: View {
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

struct OnboardingSuccessBadge: View {
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
