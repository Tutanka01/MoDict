import AppKit
import SwiftUI

/// Owns the onboarding window's lifecycle. The window itself is a fixed 520×600
/// chromeless panel; the SwiftUI `OnboardingView` inside it drives the real
/// permission/model/dictation actions. While onboarding is on screen the app runs
/// as a regular (Dock + menu) application so the window can take focus for the
/// "Try it" dictation; it drops back to `.accessory` the moment the window leaves.
@MainActor
final class OnboardingController {

    private let app: AppModel
    private var window: NSWindow?
    private var windowDelegate: OnboardingWindowDelegate?

    init(app: AppModel) {
        self.app = app
    }

    /// True on first launch, whenever a required permission is missing, or when the
    /// speech model has not been downloaded yet — i.e. the app isn't ready to dictate.
    static func isNeeded(settings: SettingsStore) -> Bool {
        !settings.onboardingCompleted
            || !Permissions.allGranted
            || !FluidAudioEngine.modelsExistOnDisk()
    }

    func present() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let size = NSSize(width: 520, height: 600)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor
        // Fully guided flow — no traffic lights. The window is dismissed only by
        // finishing (or ⌘Q from the app menu while in .regular mode).
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        let root = OnboardingView(app: app) { [weak self] in
            self?.finish()
        }
        window.contentView = NSHostingView(rootView: root)
        window.setContentSize(size)
        window.center()

        let delegate = OnboardingWindowDelegate { [weak self] in
            self?.handleClose()
        }
        window.delegate = delegate

        self.window = window
        self.windowDelegate = delegate

        window.makeKeyAndOrderFront(nil)
    }

    /// Called by the view's final button. The view has already flipped
    /// `onboardingCompleted`; make sure the pipeline is live, then dismiss.
    private func finish() {
        app.controller.activate()
        window?.close()
    }

    private func handleClose() {
        NSApp.setActivationPolicy(.accessory)
        window?.delegate = nil
        window = nil
        windowDelegate = nil
    }
}

/// Bridges `windowWillClose` back to the controller. NSWindow holds its delegate
/// weakly, so the controller keeps a strong reference for us.
@MainActor
private final class OnboardingWindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
