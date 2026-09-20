import AppKit
import SwiftUI

struct MenuBarView: View {
    @ObservedObject private var controller: DictationController
    @ObservedObject private var settings: SettingsStore
    @ObservedObject private var history: HistoryStore
    @ObservedObject private var usage: UsageStore
    @Environment(\.openSettings) private var openSettings
    @AppStorage("settingsPane") private var settingsPane: SettingsPane = .general
    @State private var copiedID: UUID?
    @State private var copyResetTask: Task<Void, Never>?
    @State private var confirmingClear = false

    init(app: AppModel) {
        _controller = ObservedObject(wrappedValue: app.controller)
        _settings = ObservedObject(wrappedValue: app.settings)
        _history = ObservedObject(wrappedValue: app.history)
        _usage = ObservedObject(wrappedValue: app.usage)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                AppGlyph(size: 30)
                Text("MoDict").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button {
                    controller.setDictationEnabled(!settings.dictationEnabled)
                } label: {
                    Label(settings.dictationEnabled ? "Pause" : "Resume",
                          systemImage: settings.dictationEnabled ? "pause" : "play")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(settings.dictationEnabled ? "Pause dictation" : "Resume dictation")
            }
            .padding(16)

            MenuBar.StatusRow(status: status, onAction: performStatusAction)
                .padding(.horizontal, 12)

            Button { showSettings(.model) } label: {
                HStack(spacing: 6) {
                    Image(systemName: settings.speechModel.isCloud ? "cloud" : "lock.shield")
                    Text(settings.speechModel.isCloud ? "Cloud" : "On this Mac")
                    Text("·")
                    Text(settings.speechModel.displayName).lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Choose a speech model")

            Divider().padding(.horizontal, 16)
            historySection

            if usage.snapshot.hasSpend {
                Divider().padding(.horizontal, 16)
                Button { showSettings(.usage) } label: {
                    HStack {
                        Label("Today", systemImage: "chart.bar")
                        Spacer()
                        Text(UsageFormat.cost(usage.snapshot.todayUSD)).monospacedDigit()
                        Text("USD").foregroundStyle(.tertiary)
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("View usage and all-time costs")
            }

            Divider().padding(.horizontal, 16)
            HStack {
                Button { showSettings(.general) } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .keyboardShortcut(",", modifiers: .command)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(16)
        }
        .frame(width: 360)
        .tint(.primary)
        .onAppear { controller.recheckPermissions() }
        .task { await usage.refresh() }
        .onDisappear { copyResetTask?.cancel(); copiedID = nil }
        .confirmationDialog("Clear recent dictations?", isPresented: $confirmingClear) {
            Button("Clear recent dictations", role: .destructive) { history.clear() }
        } message: {
            Text("These copies will be removed. Text already pasted into your apps is unaffected.")
        }
    }

    private var status: MenuBar.Status {
        MenuBar.Status.make(phase: controller.phase, modelState: controller.modelState,
                            model: settings.speechModel, userIssue: controller.userIssue,
                            partial: controller.partialTranscript, enabled: settings.dictationEnabled,
                            dictationKey: settings.dictationKey, mode: settings.hotkeyMode)
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("RECENT DICTATIONS")
                    .font(.system(size: 10, weight: .semibold)).tracking(1)
                Spacer()
                if !history.items.isEmpty {
                    Button("Clear") { confirmingClear = true }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 16)
            if history.items.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your next thought starts here.")
                        .font(.system(size: 14, weight: .medium))
                    Text("Dictate in any app. Your last five dictations will be here, ready to copy again.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(history.items) { item in
                            MenuBar.HistoryRow(item: item, copied: copiedID == item.id) { copy(item) }
                        }
                    }
                }
                .frame(height: min(CGFloat(history.items.count) * 80, 320))
                Label("This session only · Never saved to disk", systemImage: "lock")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
        }
        .padding(.bottom, 6)
    }

    private func showSettings(_ pane: SettingsPane) {
        settingsPane = pane
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
    }

    private func performStatusAction() {
        switch status.action {
        case .retry, .download: controller.prepareEngine()
        case .resume: controller.setDictationEnabled(true)
        case .settings(let pane): showSettings(pane)
        case nil: break
        }
    }

    private func copy(_ item: HistoryStore.Item) {
        history.copyToClipboard(item)
        copiedID = item.id
        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            copiedID = nil
        }
    }
}

enum MenuBar {
    /// Everything the status line needs, derived from the controller's phase and
    /// model state (plus the master enable switch).
    struct Status {
        var text: String
        var symbol: String
        var detail: String?
        var isRecording = false
        var isError = false
        enum Action: Equatable {
            case retry, download, resume, settings(SettingsPane)
        }
        var action: Action?
        var actionTitle: String?
        var fraction: Double?
        /// One quiet line of the live transcript while recording (tail only).
        var liveText: String?

        static func make(phase: DictationController.Phase,
                         modelState: DictationController.ModelState,
                         model: SpeechModel,
                         userIssue: DictationController.UserIssue?,
                         partial: PartialTranscript?,
                         enabled: Bool,
                         dictationKey: DictationKey,
                         mode: HotkeyMonitor.Mode = .pushToTalk) -> Status {
            let readyText = "Ready when you are"
            let readyDetail = DictationGesture.instruction(key: dictationKey, mode: mode)
            let cloudDetail = model.isCloud ? "Audio is sent to OpenRouter when you stop." : nil
            switch phase {
            case .recording:
                return Status(text: "Recording…", symbol: "waveform", detail: cloudDetail, isRecording: true,
                              liveText: liveLine(partial))
            case .transcribing:
                return Status(text: "Transcribing…", symbol: "waveform", detail: cloudDetail,
                              liveText: liveLine(partial))
            case .idle:
                break
            }

            guard enabled else {
                return Status(text: "Dictation paused", symbol: "pause.circle", detail: "Resume whenever you are ready to speak.", action: .resume, actionTitle: "Resume dictation")
            }

            if case .ready = modelState, let userIssue {
                return Status(text: userIssue.statusTitle,
                              symbol: userIssue.symbol,
                              detail: userIssue.statusDetail,
                              isError: true,
                              action: issueAction(userIssue),
                              actionTitle: issueAction(userIssue) == nil ? nil : "Review settings")
            }

            switch modelState {
            case .ready:
                return Status(text: readyText, symbol: model.isCloud ? "cloud" : "waveform", detail: readyDetail)
            case .downloading(let progress):
                switch progress.phase {
                case .downloading:
                    let pct = Int((progress.fraction * 100).rounded())
                    return Status(text: "Downloading speech model… \(pct)%",
                                  symbol: "arrow.down.circle",
                                  fraction: min(max(progress.fraction, 0), 1))
                case .checking:
                    return Status(text: "Checking speech model…", symbol: "arrow.down.circle")
                case .compiling:
                    return Status(text: "Preparing speech model…", symbol: "arrow.down.circle")
                case .ready:
                    return Status(text: readyText, symbol: model.isCloud ? "cloud" : "waveform", detail: readyDetail)
                }
            case .needsDownload:
                return Status(text: "Speech model needs download",
                              symbol: "arrow.down.circle",
                              detail: "Download once to transcribe on this Mac.",
                              action: .download, actionTitle: "Download model")
            case .needsAPIKey:
                return Status(text: "OpenRouter API key needed",
                              symbol: "key",
                              detail: "Connect your account to use this cloud model.",
                              action: .settings(.model), actionTitle: "Add API key")
            case .unknown:
                return Status(text: "Starting speech model…", symbol: "ellipsis.circle")
            case .failed(let message):
                return Status(text: "Speech model setup failed",
                              symbol: "exclamationmark.triangle",
                              detail: modelFailureDetail(message),
                              isError: true,
                              action: .retry, actionTitle: "Retry setup")
            }
        }

        private static func issueAction(_ issue: DictationController.UserIssue) -> Action? {
            switch issue {
            case .microphonePermissionMissing, .inputMonitoringPermissionMissing, .accessibilityPermissionMissing:
                .settings(.general)
            case .microphoneMissing, .microphoneUnavailable:
                .settings(.dictation)
            case .transcriptionFailed, .transcriptionTimedOut, .cloudTranscriptionFailed:
                .settings(.model)
            case .secureInputBlocked, .insertionFailed:
                nil
            }
        }

        private static func modelFailureDetail(_ message: String) -> String {
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Retry from the menu." : trimmed
        }

        /// Confirmed + volatile joined into one plain line; nil when empty so
        /// the status row keeps its resting height until words actually exist.
        private static func liveLine(_ partial: PartialTranscript?) -> String? {
            guard let partial else { return nil }
            let line = [partial.confirmedText, partial.volatileText]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return line.isEmpty ? nil : line
        }
    }

    struct StatusRow: View {
        let status: Status
        let onAction: () -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 9) {
                    if status.isRecording {
                        Circle().fill(Theme.recordingDot).frame(width: 7, height: 7)
                    } else {
                        Image(systemName: status.symbol)
                            .foregroundStyle(status.isError ? Color.red : Color.secondary)
                    }
                    Text(status.text)
                        .font(.system(size: 15, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let detail = status.detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(detail)
                }
                if let live = status.liveText {
                    Text(live)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.head)
                }
                if let fraction = status.fraction {
                    ProgressView(value: fraction).tint(.primary)
                        .accessibilityLabel("Model download")
                }
                if let title = status.actionTitle {
                    Button(title, action: onAction)
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    struct HistoryRow: View {
        let item: HistoryStore.Item
        let copied: Bool
        let onCopy: () -> Void
        @State private var hovering = false
        @State private var showingText = false

        var body: some View {
            HStack(alignment: .center, spacing: 4) {
                Button(action: onCopy) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(item.text)
                            .font(.system(size: 13))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        HStack(spacing: 6) {
                            Text(item.date, style: .time)
                            if let cost = item.costUSD, cost > 0 {
                                Text("·")
                                Text(UsageFormat.cost(cost)).monospacedDigit()
                            }
                            Spacer()
                            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy dictation: \(item.text)")
                .accessibilityValue(copied ? "Copied" : "")

                Button { showingText = true } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14))
                        .frame(width: 28, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Read full dictation")
                .help("Read full dictation")
                .popover(isPresented: $showingText) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Dictation").font(.headline)
                            Spacer()
                            Button(copied ? "Copied" : "Copy", action: onCopy)
                        }
                        ScrollView {
                            Text(item.text)
                                .font(.system(size: 14))
                                .lineSpacing(4)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 320)
                    }
                    .padding(20)
                    .frame(width: 380)
                }
            }
            .padding(.trailing, 4)
            .background(.primary.opacity(hovering ? 0.055 : 0.025), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 12)
            .onHover { hovering = $0 }
        }
    }
}
