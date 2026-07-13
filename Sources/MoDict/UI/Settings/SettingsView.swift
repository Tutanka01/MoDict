import SwiftUI
import AppKit

/// Settings scene content. A System-Settings-style `TabView` at 460 pt wide —
/// wide enough for the two vocabulary fields to breathe. Monochrome: standard
/// `Form` controls tinted `.primary` so nothing colours the interface but the
/// system red owned by the HUD (see Docs/DESIGN.md).
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

            SettingsModelTab(controller: controller)
                .tabItem { Label("Model", systemImage: "cpu") }

            SettingsAboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .tint(.primary)
        .frame(width: 460)
        .frame(minHeight: 340)
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

            Section {
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
                Text("Automatic detects the spoken language for each utterance.")
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
            } footer: {
                Text("Near pointer shows a private preview where you are working; text is pasted only when dictation stops.")
            }
        }
        .formStyle(.grouped)
        .onAppear { inputDevices = MicrophoneCapture.availableInputDevices() }
    }
}

/// One vocabulary rule: two plain fields joined by an arrow, with a remove control
/// that surfaces on hover. Editing either field mutates the store, which persists.
/// Fixed-width arrow and remove columns keep the fields aligned across rows.
private struct VocabularyRuleRow: View {
    @Binding var rule: VocabularyRule
    @FocusState.Binding var focusedRule: UUID?
    let onRemove: () -> Void

    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            TextField("Heard", text: $rule.phrase)
                .textFieldStyle(.plain)
                .focused($focusedRule, equals: rule.id)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "arrow.right")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 16)
            TextField("Replace with", text: $rule.replacement)
                .textFieldStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onRemove) {
                Image(systemName: "minus.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(hovered ? 1 : 0)
            .frame(width: 16)
            .accessibilityLabel("Remove rule")
        }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .onHover { hovered = $0 }
    }
}

// MARK: - Model

private struct SettingsModelTab: View {
    @ObservedObject var controller: DictationController

    private static let attribution =
        "Model: NVIDIA Parakeet-TDT 0.6B v3 (CC-BY-4.0) · Runtime: FluidAudio (Apache-2.0)"

    private var isDownloading: Bool {
        if case .downloading = controller.modelState { return true }
        return false
    }

    private var statusText: String {
        switch controller.modelState {
        case .unknown:
            return "Checking…"
        case .needsDownload:
            return "Not downloaded"
        case .downloading(let progress):
            switch progress.phase {
            case .checking: return "Checking…"
            case .downloading: return "Downloading \(Int((progress.fraction * 100).rounded()))%"
            case .compiling: return "Compiling…"
            case .ready: return "Ready"
            }
        case .ready:
            return "Ready"
        case .failed:
            return "Download failed"
        }
    }

    private var failureMessage: String? {
        if case .failed(let message) = controller.modelState { return message }
        return nil
    }

    private var downloadProgress: Double? {
        if case .downloading(let progress) = controller.modelState { return progress.fraction }
        return nil
    }

    private var sizeText: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB]
        return formatter.string(fromByteCount: FluidAudioEngine.approximateDownloadBytes)
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
                        Text("Parakeet v3")
                            .font(.system(size: 13, weight: .semibold))
                        Text("\(statusText) · ≈ \(sizeText)")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }

                if let progress = downloadProgress {
                    ProgressView(value: progress)
                }

                if let failureMessage {
                    Text(failureMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Re-download") { controller.prepareEngine(force: true) }
                        .disabled(isDownloading)
                    Spacer()
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([FluidAudioEngine.modelsDirectory])
                    }
                }
            } footer: {
                Text(Self.attribution)
            }
        }
        .formStyle(.grouped)
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
            } header: {
                Text("Licenses")
            } footer: {
                Text("Local, on-device dictation. Your speech never leaves this Mac.")
            }
        }
        .formStyle(.grouped)
    }
}
