import AppKit
import AVFoundation
import ApplicationServices
import CoreGraphics

/// TCC permission helpers. MoDict needs three:
/// - Microphone (record speech)
/// - Input Monitoring (CGEventTap listening for the right ⌘ key)
/// - Accessibility (posting the synthetic ⌘V that types the text)
enum Permissions {

    enum Pane {
        case microphone
        case accessibility
        case inputMonitoring

        var settingsURL: URL {
            let anchor: String
            switch self {
            case .microphone: anchor = "Privacy_Microphone"
            case .accessibility: anchor = "Privacy_Accessibility"
            case .inputMonitoring: anchor = "Privacy_ListenEvent"
            }
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
        }
    }

    // MARK: Microphone

    static var microphoneGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static var microphoneDenied: Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        return status == .denied || status == .restricted
    }

    static func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        default:
            return false
        }
    }

    // MARK: Accessibility (post events)

    static var accessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    /// Triggers the system prompt (adds the app to the Accessibility list).
    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    // MARK: Input Monitoring (listen to events)

    static var inputMonitoringGranted: Bool {
        CGPreflightListenEventAccess()
    }

    /// Triggers the system Input Monitoring prompt.
    static func requestInputMonitoring() {
        CGRequestListenEventAccess()
    }

    // MARK: Common

    static var allGranted: Bool {
        microphoneGranted && accessibilityGranted && inputMonitoringGranted
    }

    static func openSettings(pane: Pane) {
        NSWorkspace.shared.open(pane.settingsURL)
    }
}
