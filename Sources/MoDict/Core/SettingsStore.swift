import Foundation
import Combine
import ServiceManagement

/// User preferences, persisted to UserDefaults. All access on the main actor.
@MainActor
final class SettingsStore: ObservableObject {

    enum HUDPosition: String, CaseIterable {
        case bottomCenter
        case topCenter
    }

    @Published var hotkeyMode: HotkeyMonitor.Mode {
        didSet { defaults.set(hotkeyMode.rawValue, forKey: "hotkeyMode") }
    }
    @Published var dictationKey: DictationKey {
        didSet { defaults.set(dictationKey.rawValue, forKey: "dictationKey") }
    }
    @Published var playSounds: Bool {
        didSet { defaults.set(playSounds, forKey: "playSounds") }
    }
    @Published var hapticFeedback: Bool {
        didSet { defaults.set(hapticFeedback, forKey: "hapticFeedback") }
    }
    @Published var restoreClipboard: Bool {
        didSet { defaults.set(restoreClipboard, forKey: "restoreClipboard") }
    }
    /// Language code like "en"/"fr", or "auto".
    @Published var languageHint: String {
        didSet { defaults.set(languageHint, forKey: "languageHint") }
    }
    /// Persistent CoreAudio device UID; empty string = system default.
    @Published var inputDeviceUID: String {
        didSet { defaults.set(inputDeviceUID, forKey: "inputDeviceUID") }
    }
    @Published var hudPosition: HUDPosition {
        didSet { defaults.set(hudPosition.rawValue, forKey: "hudPosition") }
    }
    /// Keep the audio engine running between dictations (faster start, permanent orange dot).
    @Published var keepMicWarm: Bool {
        didSet { defaults.set(keepMicWarm, forKey: "keepMicWarm") }
    }
    @Published var onboardingCompleted: Bool {
        didSet { defaults.set(onboardingCompleted, forKey: "onboardingCompleted") }
    }
    /// Master switch (menu bar toggle). Not persisted as "off" surprises users at relaunch.
    @Published var dictationEnabled: Bool = true

    @Published var launchAtLogin: Bool {
        didSet {
            guard oldValue != launchAtLogin else { return }
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("MoDict: SMAppService failed: \(error)")
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hotkeyMode = HotkeyMonitor.Mode(rawValue: defaults.string(forKey: "hotkeyMode") ?? "") ?? .hybrid
        dictationKey = DictationKey(rawValue: defaults.string(forKey: "dictationKey") ?? "") ?? .rightCommand
        playSounds = defaults.object(forKey: "playSounds") as? Bool ?? true
        hapticFeedback = defaults.object(forKey: "hapticFeedback") as? Bool ?? true
        restoreClipboard = defaults.object(forKey: "restoreClipboard") as? Bool ?? true
        languageHint = defaults.string(forKey: "languageHint") ?? "auto"
        inputDeviceUID = defaults.string(forKey: "inputDeviceUID") ?? ""
        hudPosition = HUDPosition(rawValue: defaults.string(forKey: "hudPosition") ?? "") ?? .bottomCenter
        keepMicWarm = defaults.object(forKey: "keepMicWarm") as? Bool ?? false
        onboardingCompleted = defaults.bool(forKey: "onboardingCompleted")
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
