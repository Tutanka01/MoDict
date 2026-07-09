import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox
import Accelerate

/// Captures the microphone and delivers a full utterance as 16 kHz mono Float32
/// samples, ready for FluidAudio. On macOS there is no `AVAudioSession`, so device
/// selection and configuration go through CoreAudio directly.
///
/// This type lives off the main actor: the tap callback runs on a real-time audio
/// thread. All shared state is guarded by `lock`; the audio thread never touches
/// UI. See Docs/research/audio-pipeline.md for the reasoning behind every
/// non-obvious detail below.
final class MicrophoneCapture: @unchecked Sendable {

    struct InputDevice: Identifiable, Hashable, Sendable {
        var id: String { uid }
        let uid: String
        let name: String
    }

    enum CaptureError: Error {
        case noInputDevice
        case selectedDeviceUnavailable
        case deviceSelectionFailed
        case invalidFormat
        case engineStartFailed
    }

    /// Visible level 0…1, called on the audio thread at buffer rate. The caller is
    /// responsible for hopping to the main thread before touching UI.
    var onLevel: (@Sendable (Float) -> Void)?
    /// Called when capture stops unexpectedly after a successful start.
    var onFatalInterruption: (@Sendable (CaptureError) -> Void)?

    private static let targetSampleRate: Double = 16_000

    /// Recreated after every `stop()`/`cancel()` — coreaudiod releases the input
    /// aggregate cleanly when the old instance is dropped.
    private var engine = AVAudioEngine()

    /// A single converter is reused across every tap buffer of an utterance (see
    /// `handleTap` for the `.noDataNow` contract). Rebuilt when the native format
    /// changes (e.g. AirPods connect mid-session).
    private var converter: AVAudioConverter?

    private let targetFormat: AVAudioFormat = {
        // Force-unwrap: this format is always valid on supported hardware.
        AVAudioFormat(commonFormat: .pcmFormatFloat32,
                      sampleRate: MicrophoneCapture.targetSampleRate,
                      channels: 1,
                      interleaved: false)!
    }()

    private let lock = NSLock()
    private var samples: [Float] = []
    private var isRecording = false
    /// Bumped on every begin/end. Straggler tap callbacks from a previous
    /// generation compare against it and drop themselves — `removeTap` does not
    /// wait for an in-flight callback to finish.
    private var generation: UInt64 = 0

    private var currentDeviceUID: String?
    private var configObserver: NSObjectProtocol?

    // MARK: - Lifecycle

    /// Start then immediately stop the engine so CoreAudio is primed and the mic
    /// permission prompt surfaces at launch rather than on the first dictation.
    func warmUp() {
        guard hasInputDevice() else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { _, _ in }
        engine.prepare()
        try? engine.start()
        input.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
        engine = AVAudioEngine()
    }

    func start(deviceUID: String?) throws {
        // Touching `inputNode` with no input device raises an unrecoverable
        // Objective-C exception — guard first.
        guard hasInputDevice() else { throw CaptureError.noInputDevice }

        lock.lock()
        samples.removeAll(keepingCapacity: true)
        generation &+= 1
        isRecording = true
        lock.unlock()
        currentDeviceUID = deviceUID

        do {
            try openEngine(deviceUID: deviceUID)
        } catch {
            lock.lock()
            isRecording = false
            converter = nil
            lock.unlock()
            removeConfigObserver()
            engine.stop()
            engine.reset()
            engine = AVAudioEngine()
            currentDeviceUID = nil
            throw error
        }
    }

    /// Stop recording and return the accumulated utterance.
    func stop() -> [Float] {
        teardown(returningSamples: true)
    }

    /// Stop recording and discard the audio.
    func cancel() {
        _ = teardown(returningSamples: false)
    }

    // MARK: - Engine assembly

    private func openEngine(deviceUID: String?) throws {
        let input = engine.inputNode
        if let uid = deviceUID {
            guard let deviceID = Self.deviceID(forUID: uid) else {
                throw CaptureError.selectedDeviceUnavailable
            }
            try Self.setInputDevice(deviceID, on: input)
        }

        // Tap in the hardware's native format (often 48 kHz stereo). Installing a
        // tap whose format differs from the node's own raises a runtime trap.
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw CaptureError.invalidFormat
        }

        guard let conv = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw CaptureError.invalidFormat
        }
        lock.lock()
        converter = conv
        lock.unlock()

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.handleTap(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw CaptureError.engineStartFailed
        }

        installConfigObserver()
    }

    @discardableResult
    private func teardown(returningSamples: Bool) -> [Float] {
        removeConfigObserver()

        lock.lock()
        let wasRecording = isRecording
        isRecording = false
        generation &+= 1
        let collected = returningSamples ? samples : []
        samples.removeAll(keepingCapacity: true)
        converter = nil
        lock.unlock()

        if wasRecording {
            engine.inputNode.removeTap(onBus: 0)
        }
        engine.stop()
        engine.reset()
        engine = AVAudioEngine()   // fresh instance for the next utterance
        currentDeviceUID = nil
        return collected
    }

    // MARK: - Tap

    private func handleTap(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let running = isRecording
        let gen = generation
        let conv = converter
        lock.unlock()
        guard running, let conv, buffer.frameLength > 0 else { return }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        // The converter is reused across buffers, so the input block must report
        // `.noDataNow` after handing over its one buffer — NEVER `.endOfStream`,
        // which latches the converter into a terminal state that yields zero
        // samples on every subsequent utterance.
        var provided = false
        var conversionError: NSError?
        let status = conv.convert(to: output, error: &conversionError) { _, inputStatus in
            if provided {
                inputStatus.pointee = .noDataNow
                return nil
            }
            provided = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let channel = output.floatChannelData?[0] else { return }

        let count = Int(output.frameLength)
        guard count > 0 else { return }

        var rms: Float = 0
        vDSP_rmsqv(channel, 1, &rms, vDSP_Length(count))
        let level = Self.visibleLevel(rms: rms)
        let chunk = Array(UnsafeBufferPointer(start: channel, count: count))

        lock.lock()
        let accepted = isRecording && generation == gen
        if accepted {
            samples.append(contentsOf: chunk)
        }
        lock.unlock()

        if accepted {
            onLevel?(level)
        }
    }

    /// RMS → dB → perceptual 0…1 curve, calibrated so ordinary speech opens the
    /// HUD without saturating and background noise is gated out.
    private static func visibleLevel(rms: Float) -> Float {
        guard rms.isFinite, rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        let gated = (db + 52) / 20
        guard gated > 0.06 else { return 0 }
        return max(0, min(1, pow(max(0, min(1, gated)), 0.42)))
    }

    // MARK: - Configuration changes

    private func installConfigObserver() {
        removeConfigObserver()
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    private func removeConfigObserver() {
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
            configObserver = nil
        }
    }

    /// The input chain was renegotiated mid-recording (default device swap, sample
    /// rate change, AirPods over HFP). The native format has likely changed, so
    /// rebuild the engine, tap and converter while preserving the samples already
    /// captured. Runs on the main queue, serialized with `start`/`stop`.
    private func handleConfigurationChange() {
        lock.lock()
        let running = isRecording
        lock.unlock()
        guard running else { return }

        let deviceUID = currentDeviceUID

        removeConfigObserver()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
        engine = AVAudioEngine()

        // Retire the old tap's generation; keep the accumulated `samples`.
        lock.lock()
        generation &+= 1
        converter = nil
        lock.unlock()

        guard hasInputDevice() else {
            lock.lock()
            isRecording = false
            lock.unlock()
            notifyFatal(.noInputDevice)
            return
        }

        do {
            try openEngine(deviceUID: deviceUID)
        } catch {
            lock.lock()
            isRecording = false
            converter = nil
            lock.unlock()
            notifyFatal((error as? CaptureError) ?? .invalidFormat)
        }
    }

    private func notifyFatal(_ error: CaptureError) {
        onFatalInterruption?(error)
    }

    // MARK: - Device presence

    private func hasInputDevice() -> Bool {
        var deviceID = AudioDeviceID()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return status == noErr && deviceID != kAudioDeviceUnknown
    }

    // MARK: - Device enumeration & selection (CoreAudio)

    static func availableInputDevices() -> [InputDevice] {
        var devices: [InputDevice] = []
        for id in allDeviceIDs() where hasInputChannels(id) {
            guard let uid = deviceUID(for: id), let name = deviceName(for: id) else { continue }
            devices.append(InputDevice(uid: uid, name: name))
        }
        return devices
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr else {
            return []
        }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &ids) == noErr else {
            return []
        }
        return ids
    }

    private static func deviceID(forUID uid: String) -> AudioDeviceID? {
        allDeviceIDs().first { deviceUID(for: $0) == uid }
    }

    private static func setInputDevice(_ id: AudioDeviceID, on node: AVAudioInputNode) throws {
        guard let unit = node.audioUnit else { throw CaptureError.deviceSelectionFailed }
        var device = id
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &device,
            UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw CaptureError.deviceSelectionFailed }
    }

    private static func hasInputChannels(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else {
            return false
        }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else {
            return false
        }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        for buffer in list where buffer.mNumberChannels > 0 {
            return true
        }
        return false
    }

    /// UID is persistent across reboots and device re-enumeration — store this, not
    /// the transient `AudioDeviceID`.
    private static func deviceUID(for id: AudioDeviceID) -> String? {
        stringProperty(id, selector: kAudioDevicePropertyDeviceUID)
    }

    private static func deviceName(for id: AudioDeviceID) -> String? {
        stringProperty(id, selector: kAudioDevicePropertyDeviceNameCFString)
    }

    private static func stringProperty(_ id: AudioDeviceID,
                                       selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        // CoreAudio hands back a +1 CFString; go through an Unmanaged raw box so
        // Swift never forms a raw pointer to a managed CFString variable.
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var unmanaged: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &unmanaged) { pointer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value = unmanaged else { return nil }
        return value.takeRetainedValue() as String
    }
}
