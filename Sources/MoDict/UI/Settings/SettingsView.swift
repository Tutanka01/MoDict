import SwiftUI
import AppKit
import Combine

/// Native macOS Settings panes; grouped forms and semantic colors follow the
/// system appearance in both light and dark mode.
struct SettingsView: View {
    @ObservedObject private var settings: SettingsStore
    @ObservedObject private var controller: DictationController
    @ObservedObject private var vocabulary: VocabularyStore

    init(app: AppModel) {
        _settings = ObservedObject(wrappedValue: app.settings)
        _controller = ObservedObject(wrappedValue: app.controller)
        _vocabulary = ObservedObject(wrappedValue: app.vocabulary)
    }

    var body: some View {
        TabView {
            SettingsGeneralTab(settings: settings, controller: controller)
                .tabItem { Label("General", systemImage: "gearshape") }

            SettingsDictationTab(settings: settings, vocabulary: vocabulary)
                .tabItem { Label("Dictation", systemImage: "mic") }

            SettingsModelTab(settings: settings, controller: controller)
                .tabItem { Label("Model", systemImage: "cpu") }

            SettingsAboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .tint(.primary)
        .frame(width: 560, height: 540)
    }
}

// MARK: - General

private struct SettingsGeneralTab: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var controller: DictationController

    private var activationExplanation: String {
        let name = settings.dictationKey.inlineName
        switch settings.hotkeyMode {
        case .pushToTalk:
            return "Hold the \(name) key while speaking, then release to insert."
        case .toggle:
            return "Press the \(name) key to start, and again to stop."
        case .hybrid:
            return "Hold to talk, or tap once to keep recording hands-free, then tap again to stop."
        }
    }

    private var dictationKeyCaption: String {
        let name = settings.dictationKey.inlineName
        switch settings.hotkeyMode {
        case .pushToTalk: return "Hold \(name) to dictate."
        case .toggle: return "Tap \(name) to start, tap again to stop."
        case .hybrid: return "Hold \(name) to dictate, or tap to toggle."
        }
    }

    var body: some View {
        Form {
            Section {
                Picker("Activation", selection: $settings.hotkeyMode) {
                    Text("Hold").tag(HotkeyMonitor.Mode.pushToTalk)
                    Text("Toggle").tag(HotkeyMonitor.Mode.toggle)
                    Text("Hybrid").tag(HotkeyMonitor.Mode.hybrid)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                // Reload the live event tap so the new mode takes effect immediately.
                .onChange(of: settings.hotkeyMode) { controller.refreshHotkeyConfiguration() }
            } header: {
                Text("Activation")
            } footer: {
                Text(activationExplanation)
            }

            Section {
                DictationKeyPicker(selection: $settings.dictationKey) {
                    controller.refreshHotkeyConfiguration()
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 4)
            } header: {
                Text("Dictation key")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(dictationKeyCaption)
                    if settings.dictationKey == .globe {
                        Text("If the Globe key is assigned in System Settings › Keyboard, set “Press 🌐 key to” to “Do Nothing” to avoid conflicts.")
                    }
                }
            }

            Section("App behavior") {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                Toggle("Play sounds", isOn: $settings.playSounds)
                Toggle("Haptic feedback", isOn: $settings.hapticFeedback)
            }

            SettingsPermissionsSection(controller: controller)
        }
        .formStyle(.grouped)
    }
}

// MARK: - Dictation key picker

/// A row of four monochrome keycaps. Selecting one re-arms the live event tap.
/// Real buttons — keyboard focusable, with a physical press (scale-down spring).
private struct DictationKeyPicker: View {
    @Binding var selection: DictationKey
    let onChange: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ForEach(DictationKey.allCases, id: \.self) { key in
                Button {
                    guard selection != key else { return }
                    withAnimation(Theme.stateSpring) { selection = key }
                    onChange()
                } label: {
                    Keycap(key: key, selected: key == selection)
                        .contentShape(Rectangle())
                }
                .buttonStyle(KeycapPressStyle())
                .accessibilityLabel(key.displayName)
                .accessibilityAddTraits(key == selection ? .isSelected : [])
            }
        }
    }

    private struct Keycap: View {
        let key: DictationKey
        let selected: Bool

        var body: some View {
            VStack(spacing: 6) {
                Image(systemName: key.keycapSymbol)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .frame(width: Theme.keycapWidth, height: Theme.keycapHeight)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.keycapCornerRadius, style: .continuous)
                            .fill(Color.primary.opacity(selected ? 0.10 : 0.03))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.keycapCornerRadius, style: .continuous)
                            .strokeBorder(selected ? Color.primary.opacity(0.60)
                                                   : Color.primary.opacity(0.12),
                                          lineWidth: selected ? 1.5 : 1)
                    )
                    // A soft lift only under the selected cap gives it the
                    // slight depth of a real key without breaking monochrome.
                    .shadow(color: selected ? Theme.keycapSelectedShadow : .clear,
                            radius: Theme.keycapSelectedShadowRadius,
                            y: Theme.keycapSelectedShadowY)
                Text(key.shortName)
                    .font(.system(size: 10))
                    .foregroundStyle(selected ? .secondary : .tertiary)
            }
        }
    }
}

/// Tap-down feedback for the keycaps: compress like a physical key, spring back.
private struct KeycapPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? Theme.keycapPressedScale : 1)
            .animation(Theme.keycapPressSpring, value: configuration.isPressed)
    }
}

// MARK: - Permissions

/// Live view of the three TCC grants. Polls once a second while the window is
/// open (TCC has no change notification) and nudges the controller so the event
/// tap re-arms the moment Input Monitoring is granted.
private struct SettingsPermissionsSection: View {
    let controller: DictationController

    @State private var micGranted = Permissions.microphoneGranted
    @State private var accessibilityGranted = Permissions.accessibilityGranted
    @State private var inputMonitoringGranted = Permissions.inputMonitoringGranted
    @State private var pollTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Section {
            row("Microphone", granted: micGranted, pane: .microphone) {
                Permissions.openSettings(pane: .microphone)
            }
            row("Accessibility", granted: accessibilityGranted, pane: .accessibility) {
                Permissions.requestAccessibility()
                Permissions.openSettings(pane: .accessibility)
            }
            row("Input Monitoring", granted: inputMonitoringGranted, pane: .inputMonitoring) {
                Permissions.requestInputMonitoring()
                Permissions.openSettings(pane: .inputMonitoring)
            }
        } header: {
            Text("Permissions")
        } footer: {
            Text("Managed in System Settings › Privacy & Security.")
        }
        .onAppear { refresh() }
        .onReceive(pollTimer) { _ in refresh() }
    }

    private func refresh() {
        micGranted = Permissions.microphoneGranted
        accessibilityGranted = Permissions.accessibilityGranted
        inputMonitoringGranted = Permissions.inputMonitoringGranted
        controller.recheckPermissions()
    }

    private func row(_ title: String, granted: Bool, pane: Permissions.Pane,
                     action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dotted")
                .foregroundStyle(granted ? Color.primary : Color.secondary)
            Text(title)
            Spacer()
            if granted {
                Text("Granted")
                    .foregroundStyle(.secondary)
            } else {
                Button("Open Settings", action: action)
                    .controlSize(.small)
            }
        }
    }
}

// MARK: - Dictation

private struct SettingsDictationTab: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var vocabulary: VocabularyStore
    @State private var inputDevices: [MicrophoneCapture.InputDevice] = []
    @FocusState private var focusedRule: UUID?

    private var selectedDeviceMissing: Bool {
        !settings.inputDeviceUID.isEmpty
            && !inputDevices.contains { $0.uid == settings.inputDeviceUID }
    }

    var body: some View {
        Form {
            Section {
                Picker("Language", selection: $settings.languageHint) {
                    Text("Automatic").tag("auto")
                    ForEach(FluidAudioEngine.supportedLanguages, id: \.code) { language in
                        Text(language.name).tag(language.code)
                    }
                }

                Picker("Microphone", selection: $settings.inputDeviceUID) {
                    Text("System default").tag("")
                    ForEach(inputDevices) { device in
                        Text(device.name).tag(device.uid)
                    }
                    // Keep the selection stable if the saved device is unplugged.
                    if selectedDeviceMissing {
                        Text("Unavailable device").tag(settings.inputDeviceUID)
                    }
                }
            } header: {
                Text("Input")
            } footer: {
                Text("Automatic follows your Mac's language when MoDict supports it. Pinning the language you speak helps MoDict avoid decoding in another one.")
            }

            Section {
                if vocabulary.rules.isEmpty {
                    Text("Teach MoDict names and terms it mishears. \"mo dict\" becomes \"MoDict\".")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach($vocabulary.rules) { $rule in
                        VocabularyRuleRow(rule: $rule, focusedRule: $focusedRule) {
                            vocabulary.rules.removeAll { $0.id == rule.id }
                        }
                    }
                }

                Button {
                    let rule = VocabularyRule(phrase: "", replacement: "")
                    vocabulary.rules.append(rule)
                    // Focus after the new row exists in the hierarchy — setting
                    // it in the same transaction can silently miss.
                    DispatchQueue.main.async { focusedRule = rule.id }
                } label: {
                    Label("Add rule", systemImage: "plus.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } header: {
                Text("Vocabulary")
            } footer: {
                Text("Applied to every dictation, before the text is inserted.")
            }

            Section {
                Toggle("Restore clipboard after insert", isOn: $settings.restoreClipboard)
                Picker("HUD position", selection: $settings.hudPosition) {
                    Text("Near pointer").tag(SettingsStore.HUDPosition.nearPointer)
                    Text("Bottom").tag(SettingsStore.HUDPosition.bottomCenter)
                    Text("Top").tag(SettingsStore.HUDPosition.topCenter)
                }
            } header: {
                Text("Output")
            } footer: {
                Text("Near pointer shows a private preview where you are working; text is pasted only when dictation stops.")
            }
        }
        .formStyle(.grouped)
        .onAppear { inputDevices = MicrophoneCapture.availableInputDevices() }
    }
}

/// Fixed-width arrow and remove columns keep replacement fields aligned.
private struct VocabularyRuleRow: View {
    @Binding var rule: VocabularyRule
    @FocusState.Binding var focusedRule: UUID?
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            TextField("Heard", text: $rule.phrase)
                .focused($focusedRule, equals: rule.id)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "arrow.right")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 16)
            TextField("Replace with", text: $rule.replacement)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onRemove) {
                Image(systemName: "minus.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .frame(width: 16)
            .accessibilityLabel("Remove rule")
        }
    }
}

// MARK: - Model

private struct SettingsModelTab: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var controller: DictationController
    @State private var pendingDeletion: SpeechModel?
    @State private var pendingCloudSelection: SpeechModel?

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: settings.speechModel.isCloud ? "cloud" : "waveform")
                        .font(.system(size: 21, weight: .medium))
                        .frame(width: 42, height: 42)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 11))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Current model")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(settings.speechModel.displayName)
                            .font(.headline)
                        Text(settings.speechModel.isCloud
                             ? (settings.hasOpenRouterKey ? "Transcription via OpenRouter" : "API key needed")
                             : "Audio stays on this Mac")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6)
            } footer: {
                Text("Choose a model below. Your selection takes effect immediately.")
            }

            Section {
                ForEach(SpeechModel.localModels) { model in
                    ModelManagementRow(
                        model: model,
                        state: controller.modelState(for: model),
                        selected: settings.speechModel == model,
                        actionsDisabled: controller.isManagingModel,
                        onSelect: { controller.selectModel(model) },
                        onDownload: { controller.downloadModel(model) },
                        onDelete: { pendingDeletion = model }
                    )
                }
            } header: {
                Text("On this Mac")
            } footer: {
                Text(SpeechModel.localModels.map(\.attribution).joined(separator: "\n"))
            }

            Section("OpenRouter API key") {
                OpenRouterKeySection(settings: settings, controller: controller)
            }

            Section {
                ForEach(SpeechModel.cloudModels) { model in
                    HStack(spacing: 12) {
                        Image(systemName: settings.speechModel == model ? "checkmark.circle.fill" : "cloud")
                            .font(.system(size: 18))
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.displayName).font(.body.weight(.medium))
                            Text(model.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if settings.speechModel == model {
                            Text("In use").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Button("Use") { pendingCloudSelection = model }
                                .disabled(controller.isManagingModel || !settings.hasOpenRouterKey)
                        }
                    }
                    .padding(.vertical, 5)
                }
                CloudPrivacyNotice()
            } header: {
                Text("Cloud models")
            } footer: {
                Text(settings.hasOpenRouterKey ? "A network connection and OpenRouter credits are required." : "Save an API key above before using a cloud model.")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Delete \(pendingDeletion?.displayName ?? "model")?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { model in
            Button("Delete model", role: .destructive) {
                controller.deleteModel(model)
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: { model in
            Text("This removes the local \(model.displayName) files. You can download them again later.")
        }
        .confirmationDialog(
            "Use \(pendingCloudSelection?.displayName ?? "cloud model")?",
            isPresented: Binding(
                get: { pendingCloudSelection != nil },
                set: { if !$0 { pendingCloudSelection = nil } }
            ),
            presenting: pendingCloudSelection
        ) { model in
            Button("Use cloud model") {
                controller.selectModel(model)
                pendingCloudSelection = nil
            }
            Button("Cancel", role: .cancel) { pendingCloudSelection = nil }
        } message: { _ in
            Text("Each recording will be sent to OpenRouter and a model provider. Providers may retain or use data to improve models. API usage may cost money.")
        }
    }
}

struct CloudPrivacyNotice: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.shield")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 5) {
                Text("Cloud privacy")
                    .font(.subheadline.weight(.semibold))
                Text("Each recording goes to OpenRouter and its model provider. Retention and training depend on the provider; usage may cost money. Cloud dictations are limited to 10 minutes. Local models never upload audio.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Link("OpenRouter privacy policy", destination: URL(string: "https://openrouter.ai/privacy/")!)
                    .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }
}

struct OpenRouterKeySection: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var controller: DictationController
    @State private var draft = ""
    @State private var error: String?
    @State private var confirmRemoval = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(settings.hasOpenRouterKey ? "Saved in macOS Keychain" : "No key saved",
                  systemImage: settings.hasOpenRouterKey ? "checkmark.shield" : "key")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(settings.hasOpenRouterKey ? Color.primary : Color.secondary)
            SecureField(settings.hasOpenRouterKey ? "Paste a new key to replace it" : "Paste your OpenRouter API key", text: $draft)
                .textContentType(.password)
                .privacySensitive()
                .onSubmit(save)
            HStack {
                Button(settings.hasOpenRouterKey ? "Replace key" : "Save key", action: save)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if settings.hasOpenRouterKey {
                    Button("Remove key", role: .destructive) { confirmRemoval = true }
                }
            }
            .controlSize(.small)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Text("Stored in Keychain. The key is checked when you transcribe and is never shown again.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Link("Create an OpenRouter key", destination: URL(string: "https://openrouter.ai/settings/keys")!)
                .font(.caption)
        }
        .confirmationDialog("Remove the OpenRouter API key?", isPresented: $confirmRemoval) {
            Button("Remove key", role: .destructive) {
                do {
                    try settings.removeOpenRouterKey()
                    draft = ""
                    error = nil
                    controller.refreshCloudKeyState()
                } catch {
                    self.error = error.localizedDescription
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Cloud dictation will stop until you save another key. Local models are unaffected.")
        }
    }

    private func save() {
        do {
            try settings.saveOpenRouterKey(draft)
            draft = ""
            error = nil
            controller.refreshCloudKeyState()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct ModelManagementRow: View {
    let model: SpeechModel
    let state: DictationController.ModelState
    let selected: Bool
    let actionsDisabled: Bool
    let onSelect: () -> Void
    let onDownload: () -> Void
    let onDelete: () -> Void

    private var isInstalled: Bool {
        if case .ready = state { return true }
        return false
    }

    private var hasLocalFiles: Bool {
        model.modelsDirectory.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    private var statusText: String {
        switch state {
        case .unknown: "Checking…"
        case .needsDownload: "Not downloaded"
        case .needsAPIKey: "Key needed"
        case .ready: "Ready"
        case .failed: "Download failed"
        case .downloading(let progress):
            switch progress.phase {
            case .checking: "Checking…"
            case .downloading: "Downloading \(Int((progress.fraction * 100).rounded()))%"
            case .compiling: "Loading…"
            case .ready: "Ready"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "waveform")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName)
                        .font(.body.weight(.medium))
                    Text("\(model.detail) · ≈ \(sizeText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if selected {
                    Text("In use").font(.caption).foregroundStyle(.secondary)
                } else {
                    Button("Use", action: onSelect)
                        .disabled(actionsDisabled)
                }
            }

            if case .downloading(let progress) = state {
                ProgressView(value: progress.fraction)
            }

            if case .failed(let message) = state {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 10) {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if case .downloading = state {
                    EmptyView()
                } else {
                    if !isInstalled {
                        Button("Download", action: onDownload)
                            .disabled(actionsDisabled)
                    }
                    if hasLocalFiles {
                        Spacer()
                        Button("Delete", role: .destructive, action: onDelete)
                            .disabled(actionsDisabled)
                        Button("Reveal in Finder") {
                            if let directory = model.modelsDirectory {
                                NSWorkspace.shared.activateFileViewerSelecting([directory])
                            }
                        }
                    }
                }
            }
        }
        .padding(.vertical, 3)
    }

    private var sizeText: String {
        ByteCountFormatter.string(fromByteCount: model.approximateDownloadBytes, countStyle: .file)
    }
}

// MARK: - About

private struct SettingsAboutTab: View {
    private let repositoryURL = URL(string: "https://github.com/Tutanka01/MoDict")!

    private var versionText: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        if let build, build != short { return "Version \(short) (\(build))" }
        return "Version \(short)"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(.quaternary)
                        .frame(width: 40, height: 40)
                        .overlay {
                            Image(systemName: "waveform")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(.primary)
                        }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("MoDict")
                            .font(.system(size: 13, weight: .semibold))
                        Text(versionText)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Text("Created by Mohamad El Akhal")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }

                Link(destination: repositoryURL) {
                    Label("github.com/Tutanka01/MoDict", systemImage: "arrow.up.right")
                }
            }

            Section {
                Text("MoDict — AGPL-3.0")
                    .foregroundStyle(.secondary)
                Text("FluidAudio — Apache-2.0")
                    .foregroundStyle(.secondary)
                Text("Parakeet-TDT 0.6B v3 — CC-BY-4.0 · NVIDIA")
                    .foregroundStyle(.secondary)
                Text("speech-swift and Qwen3-ASR 1.7B — Apache-2.0")
                    .foregroundStyle(.secondary)
            } header: {
                Text("Licenses")
            } footer: {
                Text("Local models process audio on this Mac. Cloud models send recordings to OpenRouter when selected.")
            }
        }
        .formStyle(.grouped)
    }
}
