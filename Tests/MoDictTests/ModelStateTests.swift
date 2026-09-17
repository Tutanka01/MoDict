import Foundation
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

    @Test
    func qwenCacheRequiresTokenizerAndEveryWeightShard() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoDictTests-Qwen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try Data().write(to: directory.appendingPathComponent("vocab.json"))
        try Data().write(to: directory.appendingPathComponent("model-00001-of-00002.safetensors"))
        #expect(!QwenAudioEngine.modelsExist(at: directory))

        try Data().write(to: directory.appendingPathComponent("model-00002-of-00002.safetensors"))
        #expect(QwenAudioEngine.modelsExist(at: directory))
    }

    @Test
    func qwenLanguageHintUsesPrimarySubtagAndSupportsAutomaticDetection() {
        #expect(QwenAudioEngine.language(for: "fr-FR") == "fr")
        #expect(QwenAudioEngine.language(for: "auto") == nil)
        #expect(QwenAudioEngine.language(for: nil) == nil)
    }
}
