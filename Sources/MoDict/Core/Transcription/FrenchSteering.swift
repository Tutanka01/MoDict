import CoreML
import FluidAudio
import Foundation

/// Keeps Parakeet v3 writing French while the user dictates French.
///
/// Parakeet-TDT 0.6B v3 has no language prompt. On spontaneous French it can
/// slide into English, often as a word-for-word translation ("Et ces logiciels
/// là, historiquement…" → "These logic, historically…"). FluidAudio's French
/// blocklist swaps a few dozen English function words one token at a time, but
/// once the prediction network has emitted English, the joint keeps ranking
/// English continuations first and French falls out of its top 64.
///
/// The fix acts one step earlier, on the encoder frames the joint reads: a fixed
/// "French direction" is added to every encoder step (activation steering). It
/// is the mean encoder frame at French token emissions minus the mean frame at
/// English token emissions, measured on ~790 spontaneous French utterances in
/// which the model drifted. Every French decode, the live preview included, uses
/// a mild strength; a first pass that still reads as English is decoded again at
/// twice the strength. Method, data and measurements:
/// Docs/research/french-language-drift.md.
enum FrenchSteering {
    /// Every French decode, including the live preview.
    static let baselineStrength: Float = 1
    /// The re-decode of a first pass that drifted into English. Stronger values
    /// start to delete words (3 already costs recall on clean speech).
    static let driftStrength: Float = 2

    /// Direction in Parakeet v3 encoder-output space: 1024 little-endian Float32
    /// values, L2 norm ≈ 0.17 against ≈ 0.89 for a typical speech frame.
    static let direction: [Float] = {
        let base64 = encodedDirection.joined()
        guard let data = Data(base64Encoded: base64),
              data.count == dimension * MemoryLayout<Float>.size
        else { return [] }
        return data.withUnsafeBytes { raw in
            (0..<dimension).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(
                fromByteOffset: $0 * MemoryLayout<UInt32>.size, as: UInt32.self))) }
        }
    }()

    static let dimension = 1024

    /// The same loaded models behind a steered joint. Everything else is shared
    /// by reference, so this costs no second load, compile or ANE placement.
    static func steered(_ models: AsrModels, strength: Float) -> AsrModels {
        AsrModels(
            encoder: models.encoder,
            preprocessor: models.preprocessor,
            decoder: models.decoder,
            joint: SteeredJointModel(steering: models.joint, direction: direction, strength: strength),
            ctcHead: models.ctcHead,
            configuration: models.configuration,
            vocabulary: models.vocabulary,
            version: models.version
        )
    }

    private static let encodedDirection: [String] = [
        "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",
    ]
}

/// Stand-in for Parakeet's joint network that adds `strength × direction` to
/// each encoder step before running the real joint. FluidAudio only ever calls
/// `prediction(from:options:)` on the joint, so batch decoding, long-form chunks
/// and the sliding-window preview are all steered without forking its decoder.
/// A step it cannot steer (unexpected shape or type) passes through untouched.
final class SteeredJointModel: MLModel, @unchecked Sendable {
    private let base: MLModel
    /// `strength × direction`, immutable, so concurrent decodes can share it.
    private let offset: [Float]

    init(steering base: MLModel, direction: [Float], strength: Float) {
        self.base = base
        self.offset = direction.map { $0 * strength }
        super.init()
    }

    override var modelDescription: MLModelDescription { base.modelDescription }
    override var configuration: MLModelConfiguration { base.configuration }

    override func prediction(from input: MLFeatureProvider) throws -> MLFeatureProvider {
        try base.prediction(from: steer(input))
    }

    override func prediction(from input: MLFeatureProvider,
                             options: MLPredictionOptions) throws -> MLFeatureProvider {
        try base.prediction(from: steer(input), options: options)
    }

    private func steer(_ input: MLFeatureProvider) throws -> MLFeatureProvider {
        guard let step = input.featureValue(for: "encoder_step")?.multiArrayValue,
              let decoderStep = input.featureValue(for: "decoder_step"),
              let steered = try Self.steeredEncoderStep(step, offset: offset)
        else { return input }
        return try MLDictionaryFeatureProvider(dictionary: [
            "encoder_step": MLFeatureValue(multiArray: steered),
            "decoder_step": decoderStep,
        ])
    }

    /// A fresh `[1, hidden, 1]` Float32 array holding `step + offset`, or nil
    /// when the step does not match the offset. The caller's buffer is never
    /// written: FluidAudio reuses it across calls. Pure, for tests.
    static func steeredEncoderStep(_ step: MLMultiArray, offset: [Float]) throws -> MLMultiArray? {
        guard step.dataType == .float32,
              step.shape.count == 3,
              step.shape[1].intValue == offset.count,
              step.count == offset.count
        else { return nil }
        let stride = step.strides[1].intValue
        let result = try MLMultiArray(shape: step.shape, dataType: .float32)
        let resultStride = result.strides[1].intValue
        let source = step.dataPointer.bindMemory(to: Float.self, capacity: (offset.count - 1) * stride + 1)
        let target = result.dataPointer.bindMemory(to: Float.self, capacity: (offset.count - 1) * resultStride + 1)
        for index in offset.indices {
            target[index * resultStride] = source[index * stride] + offset[index]
        }
        return result
    }
}

/// Reads a French-mode transcript for signs that Parakeet slid into English.
///
/// Translation drift is carried by English function words ("the", "is",
/// "which", "because", "I think"…), while legitimate English in French speech
/// is mostly content words ("un commit sur la branche master") that this
/// deliberately ignores. Function words inside a capitalized title ("Game of
/// Thrones", "The Voice") are ignored too.
enum EnglishDriftDetector {
    /// Common English function words and contractions that do not occur in
    /// French prose. French homographs ("a", "as", "on", "me", "or", "but",
    /// "off", "must", "go", "back"…) are left out on purpose.
    static let functionWords: Set<String> = [
        "about", "above", "after", "again", "against", "ago", "ain't", "all", "almost",
        "along", "already", "also", "although", "always", "am", "among", "and", "another",
        "any", "anybody", "anyone", "anything", "anyway", "anywhere", "are", "aren't",
        "around", "at", "away", "be", "became", "because", "become", "been", "before",
        "behind", "being", "below", "beside", "besides", "between", "both", "by", "came",
        "can", "can't", "cannot", "come", "could", "couldn't", "did", "didn't", "do", "does",
        "doesn't", "doing", "don't", "down", "during", "each", "either", "else", "enough",
        "even", "ever", "every", "everybody", "everyone", "everything", "everywhere", "few",
        "for", "from", "further", "gave", "get", "gets", "getting", "give", "goes", "going",
        "gone", "gonna", "got", "gotta", "had", "hadn't", "has", "hasn't", "have", "haven't",
        "having", "he", "he's", "her", "here", "hers", "herself", "him", "himself", "his",
        "how", "however", "i", "i'd", "i'll", "i'm", "i've", "in", "into", "is", "isn't", "it",
        "it's", "its", "itself", "just", "kinda", "know", "let's", "made", "make", "many",
        "may", "maybe", "might", "more", "most", "much", "my", "myself", "near", "need",
        "neither", "never", "next", "nobody", "none", "nor", "not", "nothing", "now",
        "nowhere", "of", "often", "one", "only", "onto", "other", "others", "otherwise", "our",
        "ourselves", "out", "over", "own", "perhaps", "please", "quite", "rather", "really",
        "said", "same", "say", "see", "shall", "she", "she's", "should", "shouldn't", "since",
        "so", "some", "somebody", "someone", "something", "sometimes", "somewhere", "soon",
        "still", "such", "take", "tell", "than", "thank", "thanks", "that", "that's", "the",
        "their", "theirs", "them", "themselves", "then", "there", "there's", "therefore",
        "these", "they", "they're", "they've", "thing", "things", "think", "this", "those",
        "though", "through", "thus", "till", "to", "together", "told", "too", "took", "toward",
        "towards", "under", "unless", "until", "up", "upon", "very", "wanna", "want", "was",
        "wasn't", "we", "we're", "we've", "well", "were", "weren't", "what", "what's",
        "whatever", "when", "whenever", "where", "whereas", "wherever", "whether", "which",
        "while", "who", "whoever", "whole", "whom", "whose", "why", "will", "with", "within",
        "without", "won't", "would", "wouldn't", "yeah", "yet", "you", "you'd", "you'll",
        "you're", "you've", "your", "yours", "yourself", "yourselves"
    ]

    static func isDrifting(_ text: String) -> Bool {
        englishFunctionWordCount(in: text) > 0
    }

    static func englishFunctionWordCount(in text: String) -> Int {
        var count = 0
        for run in spans(of: text) {
            for (index, word) in run.enumerated() where functionWords.contains(word.lowercased) {
                if !isInsideTitle(index, of: run) { count += 1 }
            }
        }
        return count
    }

    private struct Word {
        let lowercased: String
        let isCapitalized: Bool
    }

    /// Words grouped by punctuation-free runs; a comma or period ends a title.
    private static func spans(of text: String) -> [[Word]] {
        var spans: [[Word]] = [[]]
        var current = ""
        func flushWord() {
            let trimmed = current.trimmingCharacters(in: CharacterSet(charactersIn: "'-"))
            if !trimmed.isEmpty {
                spans[spans.count - 1].append(Word(
                    lowercased: trimmed.lowercased(),
                    isCapitalized: trimmed.first?.isUppercase ?? false
                ))
            }
            current = ""
        }
        for character in text.replacingOccurrences(of: "’", with: "'") {
            if character.isLetter || character == "'" || character == "-" {
                current.append(character)
            } else {
                flushWord()
                if !character.isWhitespace { spans.append([]) }
            }
        }
        flushWord()
        return spans.filter { !$0.isEmpty }
    }

    /// A function word sits inside a title when the maximal run around it, made
    /// of function words and capitalized words, holds a capitalized content
    /// word and at least two capitalized words in all.
    private static func isInsideTitle(_ index: Int, of words: [Word]) -> Bool {
        func belongs(_ word: Word) -> Bool {
            word.isCapitalized || functionWords.contains(word.lowercased)
        }
        var start = index, end = index
        while start > 0, belongs(words[start - 1]) { start -= 1 }
        while end < words.count - 1, belongs(words[end + 1]) { end += 1 }
        let run = words[start...end]
        let capitalized = run.filter(\.isCapitalized)
        let hasCapitalizedContent = capitalized.contains { !functionWords.contains($0.lowercased) }
        return hasCapitalizedContent && capitalized.count >= 2
    }
}
