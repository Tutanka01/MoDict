import Foundation
import Testing
@testable import MoDict

struct AudioConditionerTests {

    // MARK: - Helpers

    private func silence(_ seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(Double(AudioConditioner.sampleRate) * seconds))
    }

    private func sine(amplitude: Float, seconds: Double, frequency: Double = 440) -> [Float] {
        let count = Int(Double(AudioConditioner.sampleRate) * seconds)
        return (0..<count).map { index in
            amplitude * Float(sin(2 * Double.pi * frequency * Double(index) / Double(AudioConditioner.sampleRate)))
        }
    }

    // MARK: - Trimming

    @Test
    func trimsSilenceAroundSpeech() {
        let speech = sine(amplitude: 0.3, seconds: 0.5)
        let input = silence(1) + speech + silence(1)

        let output = AudioConditioner.condition(input)

        #expect(output.count < input.count)
        #expect(output.count > speech.count)
        // Speech plus the natural guards (100 ms leading, 300 ms trailing)
        // and at most one analysis frame of slack.
        #expect(output.count <= speech.count + 1_600 + 4_800 + 320)
    }

    @Test
    func allSilenceIsReturnedUntouched() {
        let input = silence(1)
        #expect(AudioConditioner.condition(input) == input)
    }

    @Test
    func veryShortBuffersPassThrough() {
        let input: [Float] = [0.1, -0.2, 0.3]
        #expect(AudioConditioner.condition(input) == input)
    }

    @Test
    func loudRoomNoiseDoesNotHideTheSpeech() {
        // 100 Hz room rumble well above the speech gate's uncapped 4x margin.
        let noise = sine(amplitude: 0.08, seconds: 1.4, frequency: 100)
        let speech = sine(amplitude: 0.2, seconds: 0.4)
        let input = Array(noise[0..<8_000]) + speech + Array(noise[8_000..<14_400])

        let output = AudioConditioner.condition(input)

        // Speech survives (noise alone cannot reach this peak), and a buffer
        // that is noisy throughout is left untrimmed rather than cut at random.
        let outputPeak = output.map(abs).max() ?? 0
        #expect(outputPeak > 0.15)
        #expect(output.count == input.count)
    }

    @Test
    func speechBoundsFindTheBurst() throws {
        let input = silence(0.25) + sine(amplitude: 0.2, seconds: 0.25) + silence(0.5)
        let bounds = try #require(AudioConditioner.speechBounds(in: input))

        #expect(bounds.lowerBound >= 3_600)
        #expect(bounds.lowerBound <= 4_200)
        #expect(bounds.upperBound >= 7_900)
        #expect(bounds.upperBound <= 8_400)
    }

    // MARK: - Levelling

    @Test
    func quietSpeechIsLifted() {
        let speech = sine(amplitude: 0.01, seconds: 0.6)
        let input = silence(0.2) + speech + silence(0.4)

        let output = AudioConditioner.condition(input)

        let inputPeak = input.map(abs).max() ?? 0
        let outputPeak = output.map(abs).max() ?? 0
        #expect(outputPeak > inputPeak * 2)
        #expect(outputPeak <= 0.96)
    }

    @Test
    func normalLevelSpeechIsNotAttenuated() {
        let speech = sine(amplitude: 0.3, seconds: 0.5)
        let input = silence(0.2) + speech + silence(0.3)

        let output = AudioConditioner.condition(input)

        let outputPeak = output.map(abs).max() ?? 0
        #expect(outputPeak > 0.25)
    }

    @Test
    func gainNeverPushesThePeakThroughTheCeiling() {
        // Quiet on average (mostly zeros) but already peaking at 0.9: the boost
        // must be clamped so the peak stays under the ceiling.
        var samples = [Float](repeating: 0, count: AudioConditioner.sampleRate)
        for index in stride(from: 0, to: samples.count, by: 1_600) {
            samples[index] = 0.9
        }
        let gain = AudioConditioner.levelGain(for: samples, speechRange: samples.indices)
        #expect(gain > 1)
        #expect(gain * 0.9 <= 0.950_01)
    }

    @Test
    func loudEnoughSpeechKeepsUnitGain() {
        let speech = sine(amplitude: 0.3, seconds: 0.5)
        let gain = AudioConditioner.levelGain(for: speech, speechRange: speech.indices)
        #expect(gain == 1)
    }

    // MARK: - High-pass

    @Test
    func highPassRemovesDCOffset() {
        var samples = [Float](repeating: 0.5, count: 4_000)
        AudioConditioner.highPass(&samples)

        let last = abs(samples.last ?? 1)
        #expect(last < 0.001)
    }
}
