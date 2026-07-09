import SwiftUI
import AppKit

@main
struct MoDictApp: App {
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
