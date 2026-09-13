import Foundation

/// Prepares a captured utterance for Parakeet without touching the signal beyond
/// what the model demonstrably tolerates.
///
/// Two problems motivate this:
/// 1. Parakeet's log-mel front end computes features over the *whole declared
///    buffer*, so recorded silence at the tail changes the features of the speech
///    that preceded it — NVIDIA NeMo #15757 shows a 2.2 s clip decoding to an
///    empty string once 400 ms of silence is appended. We therefore trim to the
///    speech bounds (keeping a short natural guard) instead of padding with
///    digital silence.
/// 2. Quiet input silently loses words: FluidAudio #747 measured a peak at
///    1.7–2.6% FS dropping trailing words with high confidence, recovered by
///    amplifying. We apply a conservative, peak-guarded gain lift on quiet audio
///    and leave normal-level audio alone.
///
/// Deterministic and pure so it is unit-tested independently of the audio stack.
enum AudioConditioner {

    static let sampleRate = 16_000

    /// Analysis window (20 ms) and hop (10 ms).
    private static let windowSamples = 320
    private static let hopSamples = 160

    /// Natural room tone kept before/after the detected speech.
    private static let leadingGuardSamples = 1_600    // 100 ms
    private static let trailingGuardSamples = 4_800   // 300 ms

    /// Below this the buffer is too short to analyze; returned untouched.
    private static let minimumAnalyzableSamples = windowSamples

    /// Never trim an utterance below half a second of retained audio.
    private static let minimumRetainedSamples = 8_000 // 500 ms

    /// Speech-band gain target (~-22 dBFS RMS). Only quiet audio is lifted —
    /// loud audio already transcribes fine, and attenuating it adds risk with no
    /// demonstrated benefit.
    private static let targetSpeechRMS: Float = 0.08
    /// Below this ratio (i.e. already loud enough) the gain stays 1.
    private static let gainThreshold: Float = 1.25
    /// First-order high-pass corner (DC offset, rumble, handling noise).
    private static let highPassCornerHz: Float = 60
    private static let maximumGain: Float = 4      // +12 dB
    private static let peakCeiling: Float = 0.95

    /// Trim to speech boundaries, level the quiet cases, remove DC/rumble.
    static func condition(_ samples: [Float]) -> [Float] {
        guard samples.count >= minimumAnalyzableSamples else { return samples }

        guard let bounds = speechBounds(in: samples) else {
            // No frame crossed the gate. Leave the buffer alone: trimming noise
            // only risks destroying a very quiet utterance, and levelling it
            // would amplify the noise floor.
            return samples
        }

        var start = bounds.lowerBound
        var end = bounds.upperBound
        start = max(0, start - leadingGuardSamples)
        end = min(samples.count, end + trailingGuardSamples)
        if end - start < minimumRetainedSamples {
            let missing = minimumRetainedSamples - (end - start)
            start = max(0, start - missing / 2)
            end = min(samples.count, start + minimumRetainedSamples)
            start = max(0, end - minimumRetainedSamples)
        }

        let trimmed = Array(samples[start..<end])
        return finish(trimmed, speechRange: trimmed.indices)
    }

    // MARK: - Speech detection

    /// Sample range from the first to the last 20 ms frame whose RMS crosses an
    /// adaptive gate (noise floor or a small fraction of the peak, whichever is
    /// higher). Returns nil when nothing crosses — e.g. pure silence.
    static func speechBounds(in samples: [Float]) -> Range<Int>? {
        guard samples.count >= windowSamples else { return nil }

        var energies: [Float] = []
        energies.reserveCapacity(samples.count / hopSamples + 1)
        var peak: Float = 0
        var index = 0
        while index + windowSamples <= samples.count {
            var sum: Float = 0
            var framePeak: Float = 0
            for offset in 0..<windowSamples {
                let value = samples[index + offset]
                sum += value * value
                framePeak = max(framePeak, abs(value))
            }
            energies.append((sum / Float(windowSamples)).squareRoot())
            peak = max(peak, framePeak)
            index += hopSamples
        }
        guard !energies.isEmpty, peak > 0 else { return nil }

        // Room tone estimate: the quietest tenth of the frames. Percentile, not
        // minimum, so a single drop-out does not set the gate to zero.
        let sorted = energies.sorted()
        let noiseFloor = sorted[max(0, sorted.count / 10 - 1)]
        // The absolute cap matters in loud rooms: without it, a 4× margin over
        // a high noise floor would gate out speech sitting just above the room.
        let gate = min(max(noiseFloor * 4, peak * 0.01, 0.002), 0.02)

        guard let first = energies.firstIndex(where: { $0 >= gate }),
              let last = energies.lastIndex(where: { $0 >= gate })
        else { return nil }

        let start = first * hopSamples
        let end = min(samples.count, last * hopSamples + windowSamples)
        return start..<end
    }

    // MARK: - Levelling

    private static func finish(_ samples: [Float], speechRange: Range<Int>) -> [Float] {
        let gain = levelGain(for: samples, speechRange: speechRange)
        var output = samples
        if gain != 1 {
            for index in output.indices {
                output[index] *= gain
            }
        }
        highPass(&output)
        return output
    }

    /// Conservative boost toward `targetSpeechRMS`: only applied to quiet audio,
    /// capped at +12 dB, and never pushing the peak through `peakCeiling`.
    static func levelGain(for samples: [Float], speechRange: Range<Int>) -> Float {
        let range = speechRange.clamped(to: samples.indices)
        guard !range.isEmpty else { return 1 }

        var sum: Float = 0
        var peak: Float = 0
        for index in range {
            let value = samples[index]
            sum += value * value
            peak = max(peak, abs(value))
        }
        let rms = (sum / Float(range.count)).squareRoot()
        guard rms > 0, peak > 0 else { return 1 }

        let raw = targetSpeechRMS / rms
        guard raw > gainThreshold else { return 1 }

        var gain = min(raw, maximumGain)
        if peak * gain > peakCeiling {
            gain = peakCeiling / peak
        }
        return gain > 1 ? gain : 1
    }

    // MARK: - High-pass

    /// Single-pole RC high-pass (`y[n] = a·(y[n-1] + x[n] - x[n-1])`). Removes
    /// DC offset and sub-60 Hz rumble without touching speech bandwidth.
    static func highPass(_ samples: inout [Float], cornerHz: Float = highPassCornerHz) {
        guard !samples.isEmpty, cornerHz > 0 else { return }
        let a = exp(-2 * Float.pi * cornerHz / Float(sampleRate))
        var previousInput: Float = 0
        var previousOutput: Float = 0
        for index in samples.indices {
            let input = samples[index]
            let output = a * (previousOutput + input - previousInput)
            previousInput = input
            previousOutput = output
            samples[index] = output
        }
    }
}
