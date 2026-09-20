import Testing
@testable import MoDict

struct InterfaceStateTests {
    @Test @MainActor
    func menuShowsTheActualGestureAndAnActionForRecoverableStates() {
        func status(_ state: DictationController.ModelState = .ready,
                    enabled: Bool = true,
                    issue: DictationController.UserIssue? = nil,
                    phase: DictationController.Phase = .idle,
                    key: DictationKey = .rightCommand,
                    mode: HotkeyMonitor.Mode = .pushToTalk) -> MenuBar.Status {
            MenuBar.Status.make(phase: phase, modelState: state, model: .parakeetV3,
                                userIssue: issue, partial: nil, enabled: enabled,
                                dictationKey: key, mode: mode)
        }

        for key in DictationKey.allCases {
            #expect(status(key: key).detail == "Hold \(key.inlineName), speak, then release to paste.")
            #expect(status(key: key, mode: .toggle).detail == "Tap \(key.inlineName) to start. Tap again to paste.")
            #expect(status(key: key, mode: .hybrid).detail == "Hold \(key.inlineName) to talk, or tap for hands-free.")
        }
        #expect(status().action == nil)
        #expect(status(enabled: false).action == .resume)
        #expect(status(.needsDownload).action == .download)
        #expect(status(.needsAPIKey).action == .settings(.model))
        #expect(status(.failed("Offline")).action == .retry)
        #expect(status(issue: .inputMonitoringPermissionMissing).action == .settings(.general))
        #expect(status(issue: .microphoneMissing).action == .settings(.dictation))
        #expect(status(issue: .cloudTranscriptionFailed("Offline")).action == .settings(.model))
        #expect(status(issue: .secureInputBlocked).action == nil)
        // Action labels name the destination pane, not the gesture.
        #expect(status(issue: .inputMonitoringPermissionMissing).actionTitle == "Open General settings")
        #expect(status(issue: .microphoneMissing).actionTitle == "Choose a microphone")
        #expect(status(issue: .cloudTranscriptionFailed("Offline")).actionTitle == "Review model settings")
        #expect(status(issue: .secureInputBlocked).actionTitle == nil)
        #expect(status(enabled: false, phase: .recording).isRecording)
        #expect(status(phase: .transcribing).action == nil)
        #expect(status(.downloading(.init(phase: .downloading, fraction: 0.42))).fraction == 0.42)
        #expect(status(.downloading(.init(phase: .ready, fraction: 1)), mode: .toggle).detail == status(mode: .toggle).detail)
    }
}
