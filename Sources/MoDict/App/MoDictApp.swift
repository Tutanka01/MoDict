import SwiftUI
import AppKit

/// Entry point. The launch check must run *before* SwiftUI constructs the app
/// scene: `MoDictApp`'s stored properties initialize `AppModel.shared` (which
/// touches preferences and the model state) — so the check lives here, before
/// any app state exists.
@main
enum MoDictEntryPoint {
    /// Bundle check hook (see scripts/verify-bundle.sh): `MODICT_LAUNCH_CHECK=1`
    /// exits the moment dyld has resolved every library and MLX has run one real
    /// kernel. Because dyld and MLX both run before any UI, reaching this point
    /// proves the packaged app can actually start and transcribe — it never
    /// touches the UI, permissions, the model, the API key, or the network.
    static func main() {
        if ProcessInfo.processInfo.environment["MODICT_LAUNCH_CHECK"] == "1" {
            let smoke = QwenAudioEngine.runtimeSmokeTest()
            guard smoke.reduction == 9, smoke.matmul == 10 else {
                print("MODICT_LAUNCH_CHECK: MLX smoke test failed (reduction=\(smoke.reduction), matmul=\(smoke.matmul))")
                exit(EXIT_FAILURE)
            }
            print("MODICT_LAUNCH_CHECK: ok (dyld + MLX kernels)")
            exit(EXIT_SUCCESS)
        }
        MoDictApp.main()
    }
}

struct MoDictApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var controller = AppModel.shared.controller
    @ObservedObject private var settings = AppModel.shared.settings
    @ObservedObject private var usage = AppModel.shared.usage

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(app: AppModel.shared)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: menuBarSymbol)
                // Best-effort badge: macOS caches the label until hover, so it
                // only ever needs to be approximately current (opt-in anyway).
                if let amount = menuBarAmount {
                    Text(amount)
                        .monospacedDigit()
                }
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(app: AppModel.shared)
        }
    }

    /// Today's or all-time cloud spend, only when the user opted in and there is
    /// something to show — a "$0" badge would be noise.
    private var menuBarAmount: String? {
        switch settings.menuBarCost {
        case .iconOnly:
            return nil
        case .today:
            return usage.snapshot.todayUSD > 0 ? UsageFormat.cost(usage.snapshot.todayUSD) : nil
        case .total:
            return usage.snapshot.totalUSD > 0 ? UsageFormat.cost(usage.snapshot.totalUSD) : nil
        }
    }

    private var menuBarSymbol: String {
        switch controller.phase {
        case .recording, .transcribing:
            return "waveform.circle.fill"
        case .idle:
            if case .downloading = controller.modelState { return "arrow.down.circle" }
            return "waveform"
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var onboarding: OnboardingController?
    /// SwiftUI's `Settings` scene window identifier.
    private static let settingsWindowID = "com_apple_SwiftUI_Settings_window"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        adoptSettingsWindowBehavior()
        Task { @MainActor in
            let app = AppModel.shared
            if OnboardingController.isNeeded(settings: app.settings) {
                let onboarding = OnboardingController(app: app)
                self.onboarding = onboarding
                onboarding.present()
            } else {
                app.controller.activate()
            }
            await app.usage.refresh()
        }
    }

    /// The `Settings` scene window is fixed-size (SwiftUI limitation) and, in an
    /// accessory app, unreachable from the app switcher. While it is open the app
    /// behaves like a normal app — resizable window, Dock icon, ⌘-tab focus — and
    /// returns to a pure menu-bar citizen when it closes.
    private func adoptSettingsWindowBehavior() {
        let observer = NotificationCenter.default
        observer.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            self?.promoteWhileSettingsVisible(note.object as? NSWindow)
        }
        observer.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Fallback: an already-open settings window that regains focus
            // without becoming key again (e.g. clicking its title bar only).
            let window = NSApp.windows.first {
                $0.identifier?.rawValue == Self.settingsWindowID && $0.isVisible
            }
            self?.promoteWhileSettingsVisible(window)
        }
        observer.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let window = note.object as? NSWindow,
                  window.identifier?.rawValue == Self.settingsWindowID else { return }
            self?.returnToMenuBar()
        }
    }

    private func promoteWhileSettingsVisible(_ window: NSWindow?) {
        guard let window, window.identifier?.rawValue == Self.settingsWindowID else { return }
        window.styleMask.insert(.resizable)
        window.minSize = NSSize(width: 780, height: 620)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func returnToMenuBar() {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task { @MainActor in
            AppModel.shared.controller.deactivate()
        }
    }
}
