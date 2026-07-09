import AppKit
import SwiftUI

/// The `MenuBarExtra` popover (style `.window`). A quiet, monochrome panel:
/// a single status line, the last few dictations, and a small footer. No
/// explicit backgrounds — the system window material shows through.
struct MenuBarView: View {

    @ObservedObject private var controller: DictationController
    @ObservedObject private var settings: SettingsStore
    @ObservedObject private var history: HistoryStore

    /// Row that flashed a checkmark after being copied, plus the timer that clears it.
    @State private var copiedID: UUID?
    @State private var copyResetTask: Task<Void, Never>?

    init(app: AppModel) {
        _controller = ObservedObject(wrappedValue: app.controller)
        _settings = ObservedObject(wrappedValue: app.settings)
        _history = ObservedObject(wrappedValue: app.history)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuBar.StatusRow(status: status) {
                controller.prepareEngine()
            }

            Divider().padding(.horizontal, 12)

            historySection

            Divider().padding(.horizontal, 12)

            MenuBar.Footer(settings: settings, controller: controller)
        }
        .frame(width: 300)
        // Opening the popover is the natural "did my grant take?" moment after a
        // trip to System Settings — reconcile stale permission issues right away.
        .onAppear { controller.recheckPermissions() }
    }

    private var status: MenuBar.Status {
        MenuBar.Status.make(phase: controller.phase,
                            modelState: controller.modelState,
                            userIssue: controller.userIssue,
                            enabled: settings.dictationEnabled)
    }

    @ViewBuilder
    private var historySection: some View {
        if history.items.isEmpty {
            MenuBar.EmptyHistory()
        } else {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Recent")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear") { history.clear() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 2)

                ForEach(history.items) { item in
                    MenuBar.HistoryRow(item: item, copied: copiedID == item.id) {
                        copy(item)
                    }
                }
            }
            .padding(.bottom, 6)
        }
    }

    private func copy(_ item: HistoryStore.Item) {
        history.copyToClipboard(item)
        withAnimation(.easeInOut(duration: 0.15)) {
            copiedID = item.id
        }
        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                if copiedID == item.id { copiedID = nil }
            }
        }
    }
}

// MARK: - Internal views (namespaced to avoid collisions in the single target)

enum MenuBar {

    /// Everything the status line needs, derived from the controller's phase and
    /// model state (plus the master enable switch).
    struct Status {
        var text: String
        var symbol: String
        var detail: String?
        var isRecording = false
        var isError = false
        var showRetry = false
        var fraction: Double?

        static func make(phase: DictationController.Phase,
                         modelState: DictationController.ModelState,
                         userIssue: DictationController.UserIssue?,
                         enabled: Bool) -> Status {
            switch phase {
            case .recording:
                return Status(text: "Recording…", symbol: "waveform", isRecording: true)
            case .transcribing:
                return Status(text: "Transcribing…", symbol: "waveform")
            case .idle:
                break
            }

            guard enabled else {
                return Status(text: "Dictation off", symbol: "pause.circle")
            }

            if case .ready = modelState, let userIssue {
                return Status(text: userIssue.statusTitle,
                              symbol: userIssue.symbol,
                              detail: userIssue.statusDetail,
                              isError: true)
            }

            switch modelState {
            case .ready:
                return Status(text: "Ready · hold right ⌘ to dictate", symbol: "waveform")
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
                    return Status(text: "Ready · hold right ⌘ to dictate", symbol: "waveform")
                }
            case .needsDownload:
                return Status(text: "Speech model needs download",
                              symbol: "arrow.down.circle",
                              detail: "Keep MoDict open while the local model downloads.")
            case .unknown:
                return Status(text: "Starting speech model…", symbol: "ellipsis.circle")
            case .failed(let message):
                return Status(text: "Speech model setup failed",
                              symbol: "exclamationmark.triangle",
                              detail: modelFailureDetail(message),
                              isError: true,
                              showRetry: true)
            }
        }

        private static func modelFailureDetail(_ message: String) -> String {
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Retry from the menu." : trimmed
        }
    }

    struct StatusRow: View {
        let status: Status
        let onRetry: () -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    indicator
                    Text(status.text)
                        .font(.system(size: 13))
                        .foregroundStyle(status.isError ? Color.red : Color.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    if status.showRetry {
                        Button("Retry", action: onRetry)
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                if let detail = status.detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let fraction = status.fraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .tint(.primary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }

        @ViewBuilder
        private var indicator: some View {
            if status.isRecording {
                RecordingDot()
            } else {
                Image(systemName: status.symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(status.isError ? Color.red : Color.secondary)
                    .frame(width: 16)
            }
        }
    }

    /// The single red accent allowed at rest — a small pulsing recording dot.
    struct RecordingDot: View {
        @State private var pulsing = false

        var body: some View {
            Circle()
                .fill(Theme.recordingDot)
                .frame(width: 6, height: 6)
                .opacity(pulsing ? 0.35 : 1)
                .frame(width: 16)
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                        pulsing = true
                    }
                }
        }
    }

    struct EmptyHistory: View {
        var body: some View {
            VStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Your dictations will appear here")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
        }
    }

    struct HistoryRow: View {
        let item: HistoryStore.Item
        let copied: Bool
        let onCopy: () -> Void

        @State private var hovering = false

        var body: some View {
            Button(action: onCopy) {
                HStack(alignment: .top, spacing: 8) {
                    Text(item.text)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    trailingIcon
                        .frame(width: 14)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(hovering ? 0.06 : 0))
                        .padding(.horizontal, 6)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
        }

        @ViewBuilder
        private var trailingIcon: some View {
            if copied {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            } else if hovering {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    struct Footer: View {
        @ObservedObject var settings: SettingsStore
        @ObservedObject var controller: DictationController

        var body: some View {
            HStack(spacing: 16) {
                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Settings")
                .simultaneousGesture(TapGesture().onEnded {
                    NSApp.activate(ignoringOtherApps: true)
                })

                Button {
                    controller.setDictationEnabled(!settings.dictationEnabled)
                } label: {
                    Image(systemName: "power")
                }
                .buttonStyle(.plain)
                .foregroundStyle(settings.dictationEnabled ? Color.primary : Color.secondary)
                .help(settings.dictationEnabled ? "Disable dictation" : "Enable dictation")

                Spacer()

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
            .font(.system(size: 14))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }
}
