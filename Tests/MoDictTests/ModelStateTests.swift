import Testing
@testable import MoDict

struct ModelStateTests {

    @Test
    func modelDownloadProgressEqualityIncludesPhaseAndFraction() {
        let downloadingHalf = ModelDownloadProgress(phase: .downloading, fraction: 0.5)

        #expect(downloadingHalf == ModelDownloadProgress(phase: .downloading, fraction: 0.5))
        #expect(downloadingHalf != ModelDownloadProgress(phase: .compiling, fraction: 0.5))
        #expect(downloadingHalf != ModelDownloadProgress(phase: .downloading, fraction: 0.75))
    }

    @Test
    func dictationModelStateEqualityCarriesProgressAndFailureDetails() {
        let progress = ModelDownloadProgress(phase: .checking, fraction: 0)

        #expect(DictationController.ModelState.downloading(progress) == .downloading(progress))
        #expect(
            DictationController.ModelState.downloading(progress) != .downloading(ModelDownloadProgress(phase: .ready, fraction: 1))
        )
        #expect(DictationController.ModelState.failed("boom") == .failed("boom"))
        #expect(DictationController.ModelState.failed("boom") != .failed("other"))
    }

    @Test
    func hudStateEqualityCarriesErrorMessageAndSymbol() {
        #expect(HUDState.recording == .recording)
        #expect(
            HUDState.error(message: "No mic", symbol: "mic.slash") == .error(message: "No mic", symbol: "mic.slash")
        )
        #expect(
            HUDState.error(message: "No mic", symbol: "mic.slash") != .error(message: "No mic", symbol: "xmark")
        )
    }
}
