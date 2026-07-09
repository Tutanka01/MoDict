import SwiftUI
import AppKit

/// Settings scene content. A System-Settings-style `TabView` at ~420 pt wide.
/// Monochrome: standard `Form` controls tinted `.primary` so nothing colours the
/// interface but the system red owned by the HUD (see Docs/DESIGN.md).
struct SettingsView: View {
    @ObservedObject private var settings: SettingsStore
    @ObservedObject private var controller: DictationController

    init(app: AppModel) {
        _settings = ObservedObject(wrappedValue: app.settings)
        _controller = ObservedObject(wrappedValue: app.controller)
    }

    var body: some View {
        TabView {
            SettingsGeneralTab(settings: settings, controller: controller)
                .tabItem { Label("General", systemImage: "gearshape") }

            SettingsDictationTab(settings: settings)
                .tabItem { Label("Dictation", systemImage: "mic") }

            SettingsModelTab(controller: controller)
                .tabItem { Label("Model", systemImage: "cpu") }

            SettingsAboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .tint(.primary)
        .frame(width: 420)
        .frame(minHeight: 340)
    }
}

// MARK: - General

private struct SettingsGeneralTab: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var controller: DictationController

    private var activationExplanation: String {
        switch settings.hotkeyMode {
        case .pushToTalk:
            return "Hold the right Command key while speaking, then release to insert."
        case .toggle:
            return "Press the right Command key to start, and again to stop."
        case .hybrid:
            return "Hold to talk, or tap once to keep recording hands-free, then tap again to stop."
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
                .onChange(of: settings.hotkeyMode) { controller.refreshHotkeyMode() }
            } header: {
                Text("Activation")
            } footer: {
                Text(activationExplanation)
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
    @State private var inputDevices: [MicrophoneCapture.InputDevice] = []

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
                Toggle("Restore clipboard after insert", isOn: $settings.restoreClipboard)
                Picker("HUD position", selection: $settings.hudPosition) {
                    Text("Bottom").tag(SettingsStore.HUDPosition.bottomCenter)
                    Text("Top").tag(SettingsStore.HUDPosition.topCenter)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { inputDevices = MicrophoneCapture.availableInputDevices() }
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
