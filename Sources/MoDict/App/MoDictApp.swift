import SwiftUI
import AppKit

@main
struct MoDictApp: App {
    /// Bundle check hook (see scripts/verify-bundle.sh): `MODICT_LAUNCH_CHECK=1`
    /// exits the moment dyld has resolved every library and MLX has run one real
    /// kernel. Because dyld and MLX both run before any UI, reaching this point
    /// proves the packaged app can actually start and transcribe — it never
    /// touches the UI, permissions, the model, or the network.
    init() {
        if ProcessInfo.processInfo.environment["MODICT_LAUNCH_CHECK"] == "1" {
            let smoke = QwenAudioEngine.runtimeSmokeTest()
            guard smoke.reduction == 9, smoke.matmul == 10 else {
                print("MODICT_LAUNCH_CHECK: MLX smoke test failed (reduction=\(smoke.reduction), matmul=\(smoke.matmul))")
                exit(EXIT_FAILURE)
            }
            print("MODICT_LAUNCH_CHECK: ok (dyld + MLX kernels)")
            exit(EXIT_SUCCESS)
        }
    }

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var controller = AppModel.shared.controller

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(app: AppModel.shared)
        } label: {
            Image(systemName: menuBarSymbol)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(app: AppModel.shared)
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        Task { @MainActor in
            let app = AppModel.shared
            if OnboardingController.isNeeded(settings: app.settings) {
                let onboarding = OnboardingController(app: app)
                self.onboarding = onboarding
                onboarding.present()
            } else {
                app.controller.activate()
            }
        }
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
