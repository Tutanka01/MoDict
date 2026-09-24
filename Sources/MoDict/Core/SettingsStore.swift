import Foundation
import Combine
import ServiceManagement

/// User preferences, persisted to UserDefaults. All access on the main actor.
@MainActor
final class SettingsStore: ObservableObject {

    private static let nearPointerMigrationKey = "nearPointerHUDMigrationCompleted"

    enum HUDPosition: String, CaseIterable {
        case nearPointer
        case bottomCenter
        case topCenter
    }

    /// What the menu bar shows next to its icon. Icon-only by default: a
    /// permanent dollar badge is opt-in (menu bar space, screen sharing).
    enum MenuBarCost: String, CaseIterable, Identifiable {
        case iconOnly
        case today
        case total

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .iconOnly: "Icon only"
            case .today: "Today's spend"
            case .total: "Total spend"
            }
        }
    }

    @Published var hotkeyMode: HotkeyMonitor.Mode {
        didSet {
            defaults.set(hotkeyMode.rawValue, forKey: "hotkeyMode")
            if oldValue != hotkeyMode { gestureHintsRemaining = Self.guidedDictations }
        }
    }
    @Published var dictationKey: DictationKey {
        didSet {
            defaults.set(dictationKey.rawValue, forKey: "dictationKey")
            if oldValue != dictationKey { gestureHintsRemaining = Self.guidedDictations }
        }
    }
    /// How many more successful dictations still show the stop gesture and the
    /// Esc hint on the HUD. Guidance fades once the gesture is learned, and
    /// returns when the shortcut or activation mode changes.
    @Published private(set) var gestureHintsRemaining: Int {
        didSet { defaults.set(gestureHintsRemaining, forKey: "gestureHintsRemaining") }
    }
    static let guidedDictations = 8
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
    @Published var speechModel: SpeechModel {
        didSet { defaults.set(speechModel.rawValue, forKey: "speechModel") }
    }
    /// Show words while speaking. Models that don't stream (Qwen, cloud) get
    /// a preview transcribed on this Mac by Parakeet when its model is on
    /// disk; the pasted text always comes from `speechModel`.
    @Published var livePreview: Bool {
        didSet { defaults.set(livePreview, forKey: "livePreview") }
    }
    @Published private(set) var hasOpenRouterKey: Bool
    /// Persistent CoreAudio device UID; empty string = system default.
    @Published var inputDeviceUID: String {
        didSet { defaults.set(inputDeviceUID, forKey: "inputDeviceUID") }
    }
    @Published var hudPosition: HUDPosition {
        didSet { defaults.set(hudPosition.rawValue, forKey: "hudPosition") }
    }
    @Published var menuBarCost: MenuBarCost {
        didSet { defaults.set(menuBarCost.rawValue, forKey: "menuBarCost") }
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
        hasOpenRouterKey = OpenRouterKeyStore.hasKey
        hotkeyMode = HotkeyMonitor.Mode(rawValue: defaults.string(forKey: "hotkeyMode") ?? "") ?? .pushToTalk
        dictationKey = DictationKey(rawValue: defaults.string(forKey: "dictationKey") ?? "") ?? .rightCommand
        playSounds = defaults.object(forKey: "playSounds") as? Bool ?? true
        hapticFeedback = defaults.object(forKey: "hapticFeedback") as? Bool ?? true
        restoreClipboard = defaults.object(forKey: "restoreClipboard") as? Bool ?? true
        languageHint = defaults.string(forKey: "languageHint") ?? "auto"
        if let rawModel = defaults.string(forKey: "speechModel"),
           let savedModel = SpeechModel(rawValue: rawModel) {
            speechModel = savedModel
        } else {
            // Preserve Parakeet for upgrades; only fresh installs default to Qwen.
            let initialModel: SpeechModel = defaults.bool(forKey: "onboardingCompleted")
                ? .parakeetV3 : .qwen3ASR1_7B
            speechModel = initialModel
            defaults.set(initialModel.rawValue, forKey: "speechModel")
        }
        livePreview = defaults.object(forKey: "livePreview") as? Bool ?? true
        inputDeviceUID = defaults.string(forKey: "inputDeviceUID") ?? ""
        if defaults.bool(forKey: Self.nearPointerMigrationKey) {
            hudPosition = HUDPosition(rawValue: defaults.string(forKey: "hudPosition") ?? "") ?? .nearPointer
        } else {
            // The composition-card redesign replaces the old edge capsule. Move
            // existing installations to the new near-pointer experience once;
            // any position the user chooses afterwards remains respected.
            hudPosition = .nearPointer
            defaults.set(HUDPosition.nearPointer.rawValue, forKey: "hudPosition")
            defaults.set(true, forKey: Self.nearPointerMigrationKey)
        }
        keepMicWarm = defaults.object(forKey: "keepMicWarm") as? Bool ?? false
        menuBarCost = MenuBarCost(rawValue: defaults.string(forKey: "menuBarCost") ?? "") ?? .iconOnly
        onboardingCompleted = defaults.bool(forKey: "onboardingCompleted")
        if let remaining = defaults.object(forKey: "gestureHintsRemaining") as? Int {
            gestureHintsRemaining = max(0, remaining)
        } else {
            // Existing installations already know their gesture; only a fresh
            // setup starts with the guided dictations.
            gestureHintsRemaining = defaults.bool(forKey: "onboardingCompleted") ? 0 : Self.guidedDictations
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Counts one successful dictation toward learning the gesture.
    func recordGuidedDictation() {
        if gestureHintsRemaining > 0 { gestureHintsRemaining -= 1 }
    }

    func saveOpenRouterKey(_ key: String) throws {
        try OpenRouterKeyStore.save(key)
        hasOpenRouterKey = true
    }

    func removeOpenRouterKey() throws {
        try OpenRouterKeyStore.delete()
        hasOpenRouterKey = false
    }
}
