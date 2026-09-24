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
            header

            // At rest the popover is about your words; the status card only
            // appears when there is something to know or do.
            if !status.isReady {
                MenuBar.StatusRow(status: status, onAction: performStatusAction)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }

            historySection

            Divider().padding(.horizontal, 16)

            VStack(spacing: 0) {
                Button { showSettings(.model) } label: {
                    MenuBar.LinkRow(
                        symbol: settings.speechModel.isCloud ? "cloud" : "lock.shield",
                        title: settings.speechModel.isCloud ? "Cloud" : "On this Mac",
                        value: settings.speechModel.displayName
                    )
                }
                .buttonStyle(.plain)
                .help("Choose a speech model")

                if usage.snapshot.hasSpend {
                    Button { showSettings(.usage) } label: {
                        MenuBar.LinkRow(
                            symbol: "chart.bar",
                            title: "Today",
                            value: "\(UsageFormat.cost(usage.snapshot.todayUSD)) USD"
                        )
                    }
                    .buttonStyle(.plain)
                    .help("View usage and all-time costs")
                }
            }
            .padding(.vertical, 6)

            Divider().padding(.horizontal, 16)

            HStack(spacing: 16) {
                Button("Settings…") { showSettings(.general) }
                    .keyboardShortcut(",", modifiers: .command)
                Spacer()
                Button(settings.dictationEnabled ? "Pause" : "Resume") {
                    controller.setDictationEnabled(!settings.dictationEnabled)
                }
                .accessibilityLabel(settings.dictationEnabled ? "Pause dictation" : "Resume dictation")
                .keyboardShortcut("p", modifiers: .command)
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
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

    /// The mark and name; when everything is ready, the one thing worth
    /// remembering: the gesture.
    private var header: some View {
        HStack(spacing: 11) {
            AppGlyph(size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("MoDict").font(.system(size: 13, weight: .semibold))
                if status.isReady, let gesture = status.detail {
                    Text(gesture)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var status: MenuBar.Status {
        MenuBar.Status.make(phase: controller.phase, modelState: controller.modelState,
                            model: settings.speechModel, userIssue: controller.userIssue,
                            partial: controller.partialTranscript, enabled: settings.dictationEnabled,
                            dictationKey: settings.dictationKey, mode: settings.hotkeyMode)
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if !history.items.isEmpty {
                    Button("Clear") { confirmingClear = true }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            if history.items.isEmpty {
                Text("Your last five dictations appear here, ready to copy again.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(history.items) { item in
                            MenuBar.HistoryRow(item: item, copied: copiedID == item.id) { copy(item) }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
                }
                .frame(height: MenuBar.historyViewportHeight(for: history.items.count))
                Label("In memory until you quit", systemImage: "lock")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
            }
        }
        .padding(.bottom, 8)
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
    static func historyViewportHeight(for itemCount: Int) -> CGFloat {
        min(CGFloat(itemCount) * 80, 220)
    }

    /// Everything the status line needs, derived from the controller's phase and
    /// model state (plus the master enable switch).
    struct Status {
        var text: String
        var symbol: String
        var detail: String?
        var isRecording = false
        var isError = false
        /// Plain readiness: nothing to report, nothing to do.
        var isReady = false
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
                              actionTitle: issueActionTitle(userIssue))
            }

            switch modelState {
            case .ready:
                return Status(text: readyText, symbol: model.isCloud ? "cloud" : "waveform", detail: readyDetail,
                              isReady: true)
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
                    return Status(text: readyText, symbol: model.isCloud ? "cloud" : "waveform", detail: readyDetail,
                                  isReady: true)
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

        /// Name the destination, not the gesture — the button opens a specific
        /// settings pane, so the label should say which one.
        private static func issueActionTitle(_ issue: DictationController.UserIssue) -> String? {
            switch issue {
            case .microphonePermissionMissing, .inputMonitoringPermissionMissing, .accessibilityPermissionMissing:
                "Open General settings"
            case .microphoneMissing, .microphoneUnavailable:
                "Choose a microphone"
            case .transcriptionFailed, .transcriptionTimedOut, .cloudTranscriptionFailed:
                "Review model settings"
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

    /// A quiet navigation row: symbol, label, value, chevron.
    struct LinkRow: View {
        let symbol: String
        let title: String
        let value: String

        var body: some View {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .frame(width: 16)
                Text(title)
                Spacer(minLength: 8)
                Text(value)
                    .lineLimit(1)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
    }

    struct StatusRow: View {
        let status: Status
        let onAction: () -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 9) {
                    if status.isRecording {
                        Circle().fill(Theme.recordingDot).frame(width: 7, height: 7)
                    } else {
                        Image(systemName: status.symbol)
                            .foregroundStyle(status.isError ? Color.red : Color.secondary)
                    }
                    Text(status.text)
                        .font(.system(size: 14, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let detail = status.detail {
                    Text(detail)
                        .font(.system(size: 11))
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
            .padding(14)
            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    struct HistoryRow: View {
        let item: HistoryStore.Item
        let copied: Bool
        let onCopy: () -> Void
        @State private var hovering = false
        @State private var showingText = false

        var body: some View {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
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
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 0) {
                    Button(action: onCopy) {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .accessibilityLabel(copied ? "Copied dictation" : "Copy dictation: \(item.text)")
                    Button { showingText = true } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 44, height: 28)
                            .contentShape(Rectangle())
                    }
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
                .foregroundStyle(.secondary)
                .font(.system(size: 11))
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .frame(height: 76)
            .background(.primary.opacity(hovering ? 0.07 : 0.025), in: RoundedRectangle(cornerRadius: 9))
            .onHover { hovering = $0 }
        }
    }
}
