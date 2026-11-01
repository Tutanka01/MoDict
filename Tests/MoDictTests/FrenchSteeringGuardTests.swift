import Foundation
import Testing
@testable import MoDict

/// A temp directory laid out like FluidAudio's model cache, with no real model.
private struct FakeModelDirectory {
    let url: URL
    private var encoder: URL { url.appendingPathComponent("Encoder.mlmodelc", isDirectory: true) }
    var weights: URL { encoder.appendingPathComponent("weights/weight.bin") }

    func file(_ name: String) -> URL { encoder.appendingPathComponent(name) }

    init(weightBytes: Int = 8 * 1024 * 1024) throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("modict-fingerprint-\(UUID().uuidString)", isDirectory: true)
        let encoder = url.appendingPathComponent("Encoder.mlmodelc", isDirectory: true)
        try FileManager.default.createDirectory(
            at: encoder.appendingPathComponent("weights", isDirectory: true),
            withIntermediateDirectories: true
        )
        for name in ["coremldata.bin", "metadata.json", "model.mil"] {
            try Data(name.utf8).write(to: encoder.appendingPathComponent(name))
        }
        try Data(repeating: 7, count: weightBytes).write(to: weights)
    }

    func remove() { try? FileManager.default.removeItem(at: url) }

    func overwriteWeightByte(at offset: UInt64) throws {
        let handle = try FileHandle(forWritingTo: weights)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        try handle.write(contentsOf: Data([8]))
    }

    var fingerprint: String? { FrenchSteering.encoderFingerprint(inModelsDirectory: url) }
}

struct FrenchSteeringGuardTests {

    @Test
    func theFingerprintIsStableAndIsSHA256() throws {
        let model = try FakeModelDirectory()
        defer { model.remove() }
        let fingerprint = try #require(model.fingerprint)
        #expect(fingerprint.count == 64)
        let isHex = fingerprint.allSatisfy { $0.isHexDigit }
        #expect(isHex)
        #expect(model.fingerprint == fingerprint)
    }

    @Test(arguments: ["coremldata.bin", "metadata.json", "model.mil"])
    func anyChangedMetadataFileChangesIt(name: String) throws {
        let model = try FakeModelDirectory()
        defer { model.remove() }
        let before = model.fingerprint
        try Data("changed".utf8).write(to: model.file(name))
        #expect(model.fingerprint != before)
    }

    @Test
    func theWeightFileSizeChangesIt() throws {
        let model = try FakeModelDirectory()
        defer { model.remove() }
        let before = model.fingerprint
        let handle = try FileHandle(forWritingTo: model.weights)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([7]))
        try handle.close()
        #expect(model.fingerprint != before)
    }

    @Test(arguments: [0, 3_500 * 1024, 8 * 1024 * 1024 - 1] as [UInt64])
    func sampledWeightsChangeIt(offset: UInt64) throws {
        let model = try FakeModelDirectory()
        defer { model.remove() }
        let before = model.fingerprint
        try model.overwriteWeightByte(at: offset)
        #expect(model.fingerprint != before)
    }

    @Test
    func aWeightFileSmallerThanASampleStillHashes() throws {
        let model = try FakeModelDirectory(weightBytes: 100)
        defer { model.remove() }
        #expect(model.fingerprint != nil)
        let empty = try FakeModelDirectory(weightBytes: 0)
        defer { empty.remove() }
        #expect(empty.fingerprint != nil)
    }

    @Test(arguments: ["coremldata.bin", "metadata.json", "model.mil", "weights/weight.bin"])
    func aMissingFileHasNoFingerprint(name: String) throws {
        let model = try FakeModelDirectory()
        defer { model.remove() }
        try FileManager.default.removeItem(at: model.file(name))
        #expect(model.fingerprint == nil)
    }

    @Test
    func anotherEncoderTurnsSteeringOff() throws {
        let model = try FakeModelDirectory()
        defer { model.remove() }
        #expect(!FrenchSteering.isValid(forEncoderIn: model.url))
    }

    @Test
    func aMissingEncoderTurnsSteeringOff() {
        let nowhere = FileManager.default.temporaryDirectory
            .appendingPathComponent("modict-no-model-\(UUID().uuidString)", isDirectory: true)
        #expect(FrenchSteering.encoderFingerprint(inModelsDirectory: nowhere) == nil)
        #expect(!FrenchSteering.isValid(forEncoderIn: nowhere))
    }

    /// Skips without the model. When this fails after a model update, its output
    /// has the new value for `expectedEncoderFingerprint`; read that constant's
    /// comment before using it.
    @Test(.enabled(if: FileManager.default.fileExists(
        atPath: FluidAudioEngine.modelsDirectory.appendingPathComponent("Encoder.mlmodelc").path)))
    func theCachedParakeetEncoderIsTheOneSteeringWasDerivedFrom() throws {
        let directory = FluidAudioEngine.modelsDirectory
        #expect(FrenchSteering.encoderFingerprint(inModelsDirectory: directory)
            == FrenchSteering.expectedEncoderFingerprint)
        #expect(FrenchSteering.isValid(forEncoderIn: directory))

        // Best of three: this measures the work, not a loaded test machine.
        let clock = ContinuousClock()
        let times = (0..<3).map { _ in
            clock.measure { _ = FrenchSteering.encoderFingerprint(inModelsDirectory: directory) }
        }
        let fastest = try #require(times.min())
        #expect(fastest < .milliseconds(100))
    }
}
