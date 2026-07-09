import Foundation
import Testing
@testable import MoDict

@MainActor
struct SettingsStoreTests {

    @Test
    func defaultsUseExpectedValuesWhenDomainIsEmpty() {
        withEmptyDefaults { defaults in
            let store = SettingsStore(defaults: defaults)

            #expect(store.hotkeyMode == .hybrid)
            #expect(store.playSounds)
            #expect(store.hapticFeedback)
            #expect(store.restoreClipboard)
            #expect(store.languageHint == "auto")
            #expect(store.inputDeviceUID == "")
            #expect(store.hudPosition == .bottomCenter)
            #expect(!store.keepMicWarm)
            #expect(!store.onboardingCompleted)
            #expect(store.dictationEnabled)
        }
    }

    @Test
    func persistedValuesOverrideDefaults() {
        withEmptyDefaults { defaults in
            defaults.set(HotkeyMonitor.Mode.toggle.rawValue, forKey: "hotkeyMode")
            defaults.set(false, forKey: "playSounds")
            defaults.set(false, forKey: "hapticFeedback")
            defaults.set(false, forKey: "restoreClipboard")
            defaults.set("fr", forKey: "languageHint")
            defaults.set("BuiltInMicUID", forKey: "inputDeviceUID")
            defaults.set(SettingsStore.HUDPosition.topCenter.rawValue, forKey: "hudPosition")
            defaults.set(true, forKey: "keepMicWarm")
            defaults.set(true, forKey: "onboardingCompleted")

            let store = SettingsStore(defaults: defaults)

            #expect(store.hotkeyMode == .toggle)
            #expect(!store.playSounds)
            #expect(!store.hapticFeedback)
            #expect(!store.restoreClipboard)
            #expect(store.languageHint == "fr")
            #expect(store.inputDeviceUID == "BuiltInMicUID")
            #expect(store.hudPosition == .topCenter)
            #expect(store.keepMicWarm)
            #expect(store.onboardingCompleted)
        }
    }

    @Test
    func mutablePreferencesAreWrittenBackToProvidedDefaults() {
        withEmptyDefaults { defaults in
            let store = SettingsStore(defaults: defaults)

            store.hotkeyMode = .pushToTalk
            store.playSounds = false
            store.hapticFeedback = false
            store.restoreClipboard = false
            store.languageHint = "en"
            store.inputDeviceUID = "ExternalMicUID"
            store.hudPosition = .topCenter
            store.keepMicWarm = true
            store.onboardingCompleted = true

            #expect(defaults.string(forKey: "hotkeyMode") == HotkeyMonitor.Mode.pushToTalk.rawValue)
            #expect(defaults.object(forKey: "playSounds") as? Bool == false)
            #expect(defaults.object(forKey: "hapticFeedback") as? Bool == false)
            #expect(defaults.object(forKey: "restoreClipboard") as? Bool == false)
            #expect(defaults.string(forKey: "languageHint") == "en")
            #expect(defaults.string(forKey: "inputDeviceUID") == "ExternalMicUID")
            #expect(defaults.string(forKey: "hudPosition") == SettingsStore.HUDPosition.topCenter.rawValue)
            #expect(defaults.object(forKey: "keepMicWarm") as? Bool == true)
            #expect(defaults.object(forKey: "onboardingCompleted") as? Bool == true)
        }
    }

    private func withEmptyDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "MoDictTests.SettingsStore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(defaults)
    }
}
