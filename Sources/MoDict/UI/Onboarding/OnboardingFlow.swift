import Foundation

/// The five named steps of first-run setup. The speech model comes right after
/// the welcome so its download starts as early as possible and runs in the
/// background while the user grants permissions.
enum OnboardingStep: Int, CaseIterable {
    case welcome, model, microphone, access, tryIt

    var title: String {
        switch self {
        case .welcome: "Welcome"
        case .model: "Model"
        case .microphone: "Microphone"
        case .access: "Access"
        case .tryIt: "Try it"
        }
    }

    var next: OnboardingStep? { Self(rawValue: rawValue + 1) }
    var previous: OnboardingStep? { Self(rawValue: rawValue - 1) }
}

/// What setup knows about the Mac right now. Pure value: every gating decision
/// (advance, finish, send the user back) is derived here so it can be tested.
struct OnboardingReadiness: Equatable {
    var microphone: Bool
    var accessibility: Bool
    var inputMonitoring: Bool
    var model: DictationController.ModelState

    var keyboard: Bool { accessibility && inputMonitoring }

    var modelReady: Bool { model == .ready }

    /// The chosen model is ready or on its way. Its download and load run in the
    /// background, so setup does not have to wait for it.
    var modelUnderway: Bool {
        switch model {
        case .ready, .downloading: true
        case .unknown, .needsDownload, .needsAPIKey, .failed: false
        }
    }

    /// Everything dictation needs this instant.
    var dictationReady: Bool { microphone && keyboard && modelReady }

    /// Setup may finish while the model is still arriving.
    var canFinish: Bool { microphone && keyboard && modelUnderway }

    /// The condition that lets a step advance on its own. The model step waits
    /// for `ready`, not merely `underway`: it only self-advances when a model
    /// already on disk finished loading; a fresh download advances on the tap.
    func isMet(_ step: OnboardingStep) -> Bool {
        switch step {
        case .welcome, .tryIt: false
        case .model: modelReady
        case .microphone: microphone
        case .access: keyboard
        }
    }

    /// First step, in flow order, whose requirement blocks finishing.
    var firstBlockingStep: OnboardingStep? {
        if !modelUnderway { return .model }
        if !microphone { return .microphone }
        if !keyboard { return .access }
        return nil
    }
}

/// Copy for a model's download state, shared by the background dock and the steps.
enum OnboardingModelStatus {

    /// One line for the current state, or nil when there is nothing to report.
    static func title(model: SpeechModel, state: DictationController.ModelState) -> String? {
        let name = model.displayName
        switch state {
        case .downloading(let progress):
            switch progress.phase {
            case .checking: return "Checking \(name)…"
            case .downloading: return "Downloading \(name) · \(percent(progress.fraction))%"
            case .compiling: return "Preparing \(name) for this Mac…"
            case .ready: return "Finishing \(name)…"
            }
        case .ready:
            return "\(name) is ready"
        case .failed:
            return "\(name) setup stopped"
        case .unknown, .needsDownload, .needsAPIKey:
            return nil
        }
    }

    /// Determinate progress, only while bytes are actually moving.
    static func fraction(for state: DictationController.ModelState) -> Double? {
        guard case .downloading(let progress) = state, progress.phase == .downloading else { return nil }
        return min(max(progress.fraction, 0), 1)
    }

    private static func percent(_ fraction: Double) -> Int {
        Int((min(max(fraction, 0), 1) * 100).rounded())
    }
}
