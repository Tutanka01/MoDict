import Testing
@testable import MoDict

/// Locks the "auto → Mac language" rule: Parakeet v3 has no language prompt,
/// so the only way to activate FluidAudio's French English-blocklist is to
/// pass a concrete language. `nil`/`"auto"` must therefore resolve to the
/// system language when the model knows it.
struct LanguageResolutionTests {

    @Test
    func explicitHintAlwaysWins() {
        #expect(FluidAudioEngine.resolvedLanguageCode(for: "fr") == "fr")
        #expect(FluidAudioEngine.resolvedLanguageCode(for: "fr-FR") == "fr")
        #expect(FluidAudioEngine.resolvedLanguageCode(for: "de_DE") == "de")
        #expect(FluidAudioEngine.resolvedLanguageCode(for: "it") == "it")
    }

    @Test
    func automaticUsesTheMacsLanguage() {
        #expect(FluidAudioEngine.resolvedLanguageCode(
            for: "auto", preferredLanguages: ["fr-FR", "en-US"]) == "fr")
        #expect(FluidAudioEngine.resolvedLanguageCode(
            for: nil, preferredLanguages: ["fr-CA"]) == "fr")
        #expect(FluidAudioEngine.resolvedLanguageCode(
            for: "", preferredLanguages: ["de-AT"]) == "de")
    }

    @Test
    func englishAndUnknownLanguagesFallBackToModelDetection() {
        // English is the model's built-in prior; a hint would only add top-K
        // work per token while changing nothing.
        #expect(FluidAudioEngine.resolvedLanguageCode(
            for: "auto", preferredLanguages: ["en-US"]) == nil)
        #expect(FluidAudioEngine.resolvedLanguageCode(
            for: "en-GB") == nil)
        // Not one of the 25 Parakeet v3 languages.
        #expect(FluidAudioEngine.resolvedLanguageCode(for: "xx") == nil)
        #expect(FluidAudioEngine.resolvedLanguageCode(
            for: "auto", preferredLanguages: ["zh-Hans"]) == nil)
    }
}
