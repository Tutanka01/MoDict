import CoreML
import Foundation
import Testing
@testable import MoDict

/// Locks the French drift fix: the shipped steering direction, the arithmetic
/// the joint wrapper applies, and the reading of a first pass as English.
struct FrenchSteeringTests {

    // MARK: - Direction

    @Test
    func directionDecodesToTheMeasuredVector() {
        let direction = FrenchSteering.direction
        #expect(direction.count == FrenchSteering.dimension)
        let allFinite = direction.allSatisfy { $0.isFinite }
        #expect(allFinite)
        // A corrupted literal would decode to garbage or to nothing at all.
        let norm = sqrt(direction.reduce(0) { $0 + $1 * $1 })
        #expect(abs(norm - 0.1698) < 0.001)
    }

    // MARK: - Joint wrapper arithmetic

    @Test
    func steeringAddsTheOffsetWithoutTouchingTheCallersBuffer() throws {
        let step = try MLMultiArray(shape: [1, 4, 1], dataType: .float32)
        for index in 0..<4 { step[index] = NSNumber(value: Float(index)) }

        let steered = try #require(try SteeredJointModel.steeredEncoderStep(step, offset: [0.5, -1, 2, 0]))

        #expect((0..<4).map { steered[$0].floatValue } == [0.5, 0, 4, 3])
        // FluidAudio reuses the step buffer across calls: it must stay as-is.
        #expect((0..<4).map { step[$0].floatValue } == [0, 1, 2, 3])
    }

    @Test
    func steeringHonoursStridedEncoderSteps() throws {
        // Hidden values every other element, as a padded Core ML output can be.
        let storage = UnsafeMutablePointer<Float>.allocate(capacity: 6)
        storage.initialize(from: [1, -9, 2, -9, 3, -9], count: 6)
        let step = try MLMultiArray(
            dataPointer: storage,
            shape: [1, 3, 1],
            dataType: .float32,
            strides: [6, 2, 1],
            deallocator: { $0.deallocate() }
        )

        let steered = try #require(try SteeredJointModel.steeredEncoderStep(step, offset: [10, 20, 30]))

        #expect(steered.shape == [1, 3, 1])
        #expect((0..<3).map { steered[[0, NSNumber(value: $0), 0]].floatValue } == [11, 22, 33])
    }

    @Test
    func unexpectedStepsPassThroughUnsteered() throws {
        let wrongSize = try MLMultiArray(shape: [1, 3, 1], dataType: .float32)
        #expect(try SteeredJointModel.steeredEncoderStep(wrongSize, offset: [1, 2]) == nil)
        let halfPrecision = try MLMultiArray(shape: [1, 2, 1], dataType: .float16)
        #expect(try SteeredJointModel.steeredEncoderStep(halfPrecision, offset: [1, 2]) == nil)
    }

    // MARK: - Drift detection

    @Test
    func translationDriftReadsAsEnglish() {
        // Real first passes from the study (spontaneous French in, English out).
        #expect(EnglishDriftDetector.isDrifting(
            "These logic, historically, for reasons of performance history, utilities C, those things, language, still very good, because extremely difficult to maintain."))
        #expect(EnglishDriftDetector.isDrifting("Come on devine if it fera bow or it fera soleil Sylvain?"))
        #expect(EnglishDriftDetector.isDrifting("I think it's a result of pédophiles at a fire of security of Firefox."))
        #expect(EnglishDriftDetector.isDrifting("Don’t do l’traction."))
        #expect(EnglishDriftDetector.englishFunctionWordCount(
            in: "L'haltérophilie is a sport complex in how all those muscles.") == 5)
    }

    @Test
    func frenchWithEnglishTermsIsNotDrift() {
        #expect(!EnglishDriftDetector.isDrifting(
            "Donc là je fais un git add-all et ensuite un git commit sur la branche master."))
        #expect(!EnglishDriftDetector.isDrifting("On a un meeting avec la team, c'est le must pour la release."))
        // French homographs of English function words.
        #expect(!EnglishDriftDetector.isDrifting("Le but du jeu, c'est de passer en voix off."))
        #expect(!EnglishDriftDetector.isDrifting("Il a un an, on me l'a dit, or tu as vu."))
        #expect(!EnglishDriftDetector.isDrifting(""))
    }

    @Test
    func titlesAreNotDrift() {
        #expect(!EnglishDriftDetector.isDrifting("Hier j'ai regardé The Voice puis un épisode de Game of Thrones."))
        #expect(!EnglishDriftDetector.isDrifting("Il relit Lord of the Rings chaque hiver."))
        // A sentence-initial capital alone is not a title.
        #expect(EnglishDriftDetector.isDrifting("These activities complement la course."))
    }

    // MARK: - Re-decode choice

    @Test
    func redecodeIsKeptUnlessEmptyOrMoreEnglish() {
        let drifted = "These logic, historically, for reasons of performance history."
        #expect(FluidAudioEngine.prefersRedecode("Ces logiciels-là, historiquement, pour des raisons de performance.", over: drifted))
        #expect(FluidAudioEngine.prefersRedecode("These logiciels, historiquement.", over: drifted))
        #expect(!FluidAudioEngine.prefersRedecode("  ", over: drifted))
        #expect(!FluidAudioEngine.prefersRedecode("It is the thing that I think.", over: "It is the thing."))
    }
}
