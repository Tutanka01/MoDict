import Foundation
import Testing
@testable import MoDict

struct OnboardingFlowTests {

    private typealias ModelState = DictationController.ModelState

    private func readiness(
        microphone: Bool = false,
        accessibility: Bool = false,
        inputMonitoring: Bool = false,
        model: ModelState = .needsDownload
    ) -> OnboardingReadiness {
        OnboardingReadiness(microphone: microphone, accessibility: accessibility,
                            inputMonitoring: inputMonitoring, model: model)
    }

    private func downloading(_ phase: ModelDownloadProgress.Phase, _ fraction: Double) -> ModelState {
        .downloading(ModelDownloadProgress(phase: phase, fraction: fraction))
    }

    @Test
    func stepsRunWelcomeModelMicrophoneAccessTryIt() {
        #expect(OnboardingStep.allCases == [.welcome, .model, .microphone, .access, .tryIt])
        #expect(OnboardingStep.welcome.previous == nil)
        #expect(OnboardingStep.welcome.next == .model)
        #expect(OnboardingStep.tryIt.next == nil)
        #expect(OnboardingStep.tryIt.previous == .access)
    }

    @Test
    func aDownloadInProgressDoesNotBlockTheRestOfSetup() {
        let state = readiness(microphone: true, accessibility: true, inputMonitoring: true,
                              model: downloading(.downloading, 0.3))

        #expect(state.modelUnderway)
        #expect(!state.modelReady)
        #expect(!state.dictationReady)
        #expect(state.canFinish)
        #expect(state.firstBlockingStep == nil)
    }

    @Test
    func aModelThatWasNeverStartedOrThatFailedBlocksAtTheModelStep() {
        for model in [ModelState.needsDownload, .unknown, .needsAPIKey, .failed("offline")] {
            let state = readiness(microphone: true, accessibility: true, inputMonitoring: true, model: model)

            #expect(!state.canFinish)
            #expect(state.firstBlockingStep == .model)
        }
    }

    @Test
    func missingPermissionsBlockInFlowOrderOnceTheModelIsUnderway() {
        let model = downloading(.checking, 0)

        #expect(readiness(model: model).firstBlockingStep == .microphone)
        #expect(readiness(microphone: true, model: model).firstBlockingStep == .access)
        #expect(readiness(microphone: true, accessibility: true, model: model).firstBlockingStep == .access)
        #expect(readiness(microphone: true, accessibility: true, inputMonitoring: true, model: model)
            .firstBlockingStep == nil)
    }

    @Test
    func dictationNeedsAReadyModelNotJustADownloadingOne() {
        let all = readiness(microphone: true, accessibility: true, inputMonitoring: true, model: .ready)

        #expect(all.dictationReady)
        #expect(all.canFinish)
        #expect(!readiness(microphone: true, accessibility: true, inputMonitoring: false, model: .ready).dictationReady)
    }

    @Test
    func stepsAdvanceOnTheirOwnOnlyWhenTheirConditionHolds() {
        let waiting = readiness(microphone: true, accessibility: true, inputMonitoring: false,
                                model: downloading(.downloading, 0.5))

        #expect(waiting.isMet(.microphone))
        #expect(!waiting.isMet(.access))
        // A fresh download advances on the tap; only a finished load self-advances.
        #expect(!waiting.isMet(.model))
        #expect(readiness(model: .ready).isMet(.model))
        #expect(!waiting.isMet(.welcome))
        #expect(!waiting.isMet(.tryIt))
    }

    @Test
    func modelStatusNamesThePhaseAndOnlyMeasuresRealDownloads() {
        let model = SpeechModel.parakeetV3

        #expect(OnboardingModelStatus.title(model: model, state: downloading(.checking, 0)) == "Checking Parakeet v3…")
        #expect(OnboardingModelStatus.title(model: model, state: downloading(.downloading, 0.424))
            == "Downloading Parakeet v3 · 42%")
        #expect(OnboardingModelStatus.title(model: model, state: downloading(.compiling, 1))
            == "Preparing Parakeet v3 for this Mac…")
        #expect(OnboardingModelStatus.title(model: model, state: .ready) == "Parakeet v3 is ready")
        #expect(OnboardingModelStatus.title(model: model, state: .failed("x")) == "Parakeet v3 setup stopped")
        #expect(OnboardingModelStatus.title(model: model, state: .needsDownload) == nil)

        #expect(OnboardingModelStatus.fraction(for: downloading(.downloading, 0.25)) == 0.25)
        #expect(OnboardingModelStatus.fraction(for: downloading(.downloading, 1.4)) == 1)
        #expect(OnboardingModelStatus.fraction(for: downloading(.compiling, 1)) == nil)
        #expect(OnboardingModelStatus.fraction(for: .ready) == nil)
    }

    @MainActor
    @Test
    func setupReopenedForAMissingModelResumesAtTheModelStep() {
        let suiteName = "OnboardingFlowTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(defaults: defaults)

        #expect(OnboardingController.startingStep(settings: settings) == .welcome)

        settings.onboardingCompleted = true
        #expect(OnboardingController.startingStep(settings: settings) == .model)
    }
}
