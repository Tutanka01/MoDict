import CryptoKit
import Foundation

/// `FrenchSteering.direction` only means something in the output space of the
/// exact encoder it was measured on, and FluidAudio downloads from `resolve/main`
/// with no pinned revision. If the Hugging Face repository changes, a new install
/// would get a different encoder and steering that pushes in an arbitrary
/// direction. So steering runs only on the encoder it was derived from; any other
/// falls back to the plain manager with `language: .french`.
extension FrenchSteering {

    /// `encoderFingerprint(inModelsDirectory:)` of the encoder `direction` was
    /// derived from. To update it for a new encoder: derive a new `direction`
    /// (Docs/research/french-language-drift.md), then replace this with the value
    /// `FrenchSteeringGuardTests` reports against the new model. Never update it
    /// alone: this constant is what vouches for `direction`.
    static let expectedEncoderFingerprint = "1989c62eedc138fdcb0784f61108c4fad5b0da4aa2b01a34cf42daa7166a1909"

    private static let encoderDirectoryName = "Encoder.mlmodelc"
    /// What the encoder is: its program, input and output layout, and metadata.
    private static let encoderMetadataFiles = ["coremldata.bin", "metadata.json", "model.mil"]
    private static let encoderWeightsFile = "weights/weight.bin"
    /// 2 MiB of a 425 MB file, spread evenly over it. Enough to tell two exports
    /// apart; this guards against a changed repository, not against tampering.
    private static let weightSampleCount: UInt64 = 8
    private static let weightSampleBytes: UInt64 = 256 * 1024

    /// A fast SHA-256 of the encoder under a FluidAudio model directory, or nil
    /// when any part of it cannot be read: the metadata files whole, the weight
    /// file's size, and fixed samples of its weights.
    static func encoderFingerprint(inModelsDirectory directory: URL) -> String? {
        let encoder = directory.appendingPathComponent(encoderDirectoryName, isDirectory: true)
        var hash = SHA256()

        func add(_ bytes: Data) {
            withUnsafeBytes(of: UInt64(bytes.count).littleEndian) { hash.update(bufferPointer: $0) }
            hash.update(data: bytes)
        }

        do {
            for name in encoderMetadataFiles {
                add(try Data(contentsOf: encoder.appendingPathComponent(name)))
            }

            let weights = try FileHandle(forReadingFrom: encoder.appendingPathComponent(encoderWeightsFile))
            defer { try? weights.close() }
            let size = try weights.seekToEnd()
            withUnsafeBytes(of: size.littleEndian) { hash.update(bufferPointer: $0) }

            let sampleBytes = min(weightSampleBytes, size)
            let lastOffset = size - sampleBytes
            for index in 0..<weightSampleCount {
                try weights.seek(toOffset: lastOffset * index / (weightSampleCount - 1))
                add(try weights.read(upToCount: Int(sampleBytes)) ?? Data())
            }
        } catch {
            return nil
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Whether `direction` applies to the encoder under `directory`.
    static func isValid(forEncoderIn directory: URL) -> Bool {
        encoderFingerprint(inModelsDirectory: directory) == expectedEncoderFingerprint
    }
}
