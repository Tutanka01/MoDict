import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox
import Accelerate
import IOKit

/// What one utterance asked to capture from. Resolved at every open, so a default
/// that changes mid-utterance is routed by the same rules.
struct CaptureSource: Equatable, Sendable {
    /// nil = System default.
    let deviceUID: String?
    let avoidBluetooth: Bool
}

/// The hardware side of capture, separate so the sequencing in `MicrophoneCapture`
/// can be tested without a microphone. Everything but `hasInputDevice` runs on the
/// capture queue only.
protocol AudioInputEngine: AnyObject, Sendable {
    func hasInputDevice() -> Bool
    func warmUp()
    /// Builds a fresh engine and starts it. `onChunk` receives converted 16 kHz
    /// mono samples on the audio thread, and can still fire shortly after `close`.
    func open(_ source: CaptureSource,
              onChunk: @escaping @Sendable ([Float]) -> Void,
              onConfigurationChange: @escaping @Sendable () -> Void) throws
    /// Idempotent. Nothing stays open: no tap, no observer, no engine.
    func close()
}

/// Captures the microphone and delivers a full utterance as 16 kHz mono Float32
/// samples, ready for FluidAudio.
///
/// Engine lifecycle can take far longer than a frame (Bluetooth especially), so it
/// all runs on one private serial queue; no public method blocks its caller. Calls
/// are ordered by that queue, and each queued step checks `utterance` before acting
/// so an abandoned one does nothing. The audio thread never touches UI. See
/// Docs/research/audio-pipeline.md for the reasoning behind the non-obvious details.
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
    /// Converted 16 kHz mono chunk, called on the audio thread at buffer rate.
    /// Receives exactly the samples appended to the utterance (same generation
    /// guard as `onLevel`). Set once at wiring time — mutating it while the
    /// engine runs would race the tap thread.
    var onChunk: (@Sendable ([Float]) -> Void)?
    /// Called on the capture queue when capture fails after `start` returned: a
    /// late open failure or a lost device. Carries the utterance it belongs to;
    /// a caller hopping threads compares it with `isCurrent(utterance:)` on arrival,
    /// because a new utterance may have started in between. Not called while a
    /// `finish` is pending: that call returns what was captured instead.
    var onFatalInterruption: (@Sendable (CaptureError, UInt64) -> Void)?

    /// How long past the tail deadline to wait for the buffer that covers it. Tap
    /// buffers last 85 ms at 48 kHz but 256 ms at a Bluetooth headset's 16 kHz; only
    /// a device that stopped delivering ever reaches this.
    static let tailBackstop: TimeInterval = 0.3

    private let engine: any AudioInputEngine
    private let queue: DispatchQueue
    /// Owned by the queue: what a mid-utterance engine rebuild reopens.
    private var currentSource: CaptureSource?

    private let lock = NSLock()
    private var samples: [Float] = []
    private var isRecording = false
    /// Identity of the utterance; queued lifecycle steps compare against it and
    /// drop themselves. Bumped on every begin/end.
    private var utterance: UInt64 = 0
    /// Identity of the live tap, bumped on every begin/end and rebuild. Straggler
    /// callbacks of a retired tap compare against it and drop themselves —
    /// `removeTap` does not wait for an in-flight callback to finish.
    private var generation: UInt64 = 0
    private var finishWaiter: CheckedContinuation<[Float], Never>?
    private var tailDeadline: DispatchTime?
    private var captureFailure: CaptureError?
    /// Longer than the seconds a Bluetooth headset can take to switch profiles.
    private let startTimeout: TimeInterval

    init(engine: any AudioInputEngine = AVAudioInputEngine(),
         queue: DispatchQueue = DispatchQueue(label: "com.modict.capture", qos: .userInteractive),
         startTimeout: TimeInterval = 8) {
        self.engine = engine
        self.queue = queue
        self.startTimeout = startTimeout
    }

    // MARK: - Lifecycle

    /// Start then immediately stop an engine so CoreAudio is primed and the mic
    /// permission prompt surfaces at launch rather than on the first dictation.
    func warmUp() {
        queue.async { self.engine.warmUp() }
    }

    /// Accepts the utterance and returns at once; the engine opens on the queue.
    /// Throws only for what can be known right here. Anything failing later is
    /// reported through `onFatalInterruption`.
    func start(deviceUID: String?, avoidBluetooth: Bool) throws {
        guard engine.hasInputDevice() else { throw CaptureError.noInputDevice }

        lock.lock()
        // A finish still waiting on its tail ends here, with its own audio.
        let superseded = finishWaiter
        let leftover = superseded == nil ? [] : samples
        finishWaiter = nil
        tailDeadline = nil
        captureFailure = nil
        samples.removeAll(keepingCapacity: true)
        utterance &+= 1
        generation &+= 1
        isRecording = true
        let current = utterance
        lock.unlock()
        superseded?.resume(returning: leftover)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + startTimeout) {
            self.checkAudioStarted(utterance: current)
        }

        let source = CaptureSource(deviceUID: deviceUID, avoidBluetooth: avoidBluetooth)
        queue.async {
            self.currentSource = source
            self.engine.close()
            self.openEngine(source, utterance: current)
        }
    }

    /// Keeps capturing for `tail` more seconds, then stops and returns the
    /// utterance. It always returns by the deadline plus `tailBackstop`, even with
    /// the capture queue stuck on a device that will not open. A `cancel` during the
    /// tail makes it return empty.
    func finish(tail: TimeInterval) async -> [Float] {
        await withCheckedContinuation { continuation in
            lock.lock()
            guard isRecording, finishWaiter == nil else {
                // Capture already failed (keep what it got), or nothing to finish.
                let collected = finishWaiter == nil ? samples : []
                if finishWaiter == nil { samples.removeAll(keepingCapacity: true) }
                lock.unlock()
                continuation.resume(returning: collected)
                return
            }
            let deadline = DispatchTime.now() + tail
            finishWaiter = continuation
            tailDeadline = deadline
            let current = utterance
            lock.unlock()
            queue.async { self.armTail(utterance: current, deadline: deadline) }
            // Off the capture queue on purpose: that queue is what may be stuck.
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: deadline + Self.tailBackstop) {
                self.completeFinish(utterance: current)
            }
        }
    }

    /// Stop recording and discard the audio. The audio is gone before this returns;
    /// the engine closes on the queue, after anything already in progress there.
    func cancel() {
        lock.lock()
        utterance &+= 1
        generation &+= 1
        isRecording = false
        tailDeadline = nil
        samples.removeAll(keepingCapacity: true)
        let waiter = finishWaiter
        finishWaiter = nil
        lock.unlock()
        waiter?.resume(returning: [])
        queue.async { self.engine.close() }
    }

    /// Whether a failure reported for `utterance` still concerns the latest one.
    func isCurrent(utterance candidate: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return utterance == candidate
    }

    /// A `finish` is waiting on its tail (testing aid).
    var isFinishing: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finishWaiter != nil
    }

    // MARK: - Queue steps

    private func openEngine(_ source: CaptureSource, utterance expected: UInt64) {
        lock.lock()
        guard isRecording, utterance == expected else {
            lock.unlock()
            return
        }
        generation &+= 1
        let tap = generation
        lock.unlock()

        do {
            try engine.open(
                source,
                onChunk: { [weak self] chunk in
                    self?.handleChunk(chunk, tap: tap)
                },
                onConfigurationChange: { [weak self] in
                    guard let self else { return }
                    self.queue.async { self.handleConfigurationChange(tap: tap) }
                })
        } catch {
            failCapture((error as? CaptureError) ?? .engineStartFailed, utterance: expected)
        }
    }

    private func armTail(utterance expected: UInt64, deadline: DispatchTime) {
        lock.lock()
        guard utterance == expected, finishWaiter != nil else {
            lock.unlock()
            return
        }
        // Past the deadline already means the queue was held up by a rebuild or a
        // slow open; the engine has just started, no buffer is close to landing.
        // Otherwise wait, even with no audio yet: the first buffer may be about to land.
        let isDone = !isRecording || DispatchTime.now() >= deadline
        lock.unlock()

        if isDone { completeFinish(utterance: expected) }
    }

    /// The close only goes on the queue, so a slow Bluetooth stop never delays the
    /// transcription. It goes before the resume, so it precedes the open of whatever
    /// utterance the caller starts next.
    private func completeFinish(utterance expected: UInt64) {
        lock.lock()
        guard utterance == expected, let waiter = finishWaiter else {
            lock.unlock()
            return
        }
        finishWaiter = nil
        tailDeadline = nil
        utterance &+= 1
        generation &+= 1
        isRecording = false
        let collected = samples
        samples = []
        lock.unlock()
        queue.async { self.engine.close() }
        waiter.resume(returning: collected)
    }

    /// Why the capture died while nothing was listening for `onFatalInterruption`, if
    /// it did: an empty `finish` is then a microphone problem, not silence. Clears it.
    func takeCaptureFailure() -> CaptureError? {
        lock.lock()
        defer { lock.unlock() }
        let failure = captureFailure
        captureFailure = nil
        return failure
    }

    /// A device can hang inside `engine.start` with no error at all, which would
    /// otherwise look like a recording that hears nothing, for as long as the key is held.
    private func checkAudioStarted(utterance expected: UInt64) {
        lock.lock()
        let isStuck = isRecording && utterance == expected && samples.isEmpty && finishWaiter == nil
        lock.unlock()
        if isStuck { onFatalInterruption?(.engineStartFailed, expected) }
    }

    private func failCapture(_ error: CaptureError, utterance expected: UInt64) {
        engine.close()
        lock.lock()
        guard isRecording, utterance == expected else {
            lock.unlock()
            return
        }
        isRecording = false
        generation &+= 1
        captureFailure = error
        let isFinishing = finishWaiter != nil
        lock.unlock()

        if isFinishing {
            completeFinish(utterance: expected)
        } else {
            onFatalInterruption?(error, expected)
        }
    }

    /// The input chain was renegotiated mid-recording (default device swap, sample
    /// rate change, AirPods over HFP). The native format has likely changed, so
    /// rebuild the engine, tap and converter while preserving the samples already
    /// captured. During a tail there is no point reopening a device for a few
    /// milliseconds of audio, so the utterance simply ends there.
    private func handleConfigurationChange(tap: UInt64) {
        lock.lock()
        guard isRecording, generation == tap else {
            lock.unlock()
            return
        }
        generation &+= 1
        let current = utterance
        let isFinishing = finishWaiter != nil
        lock.unlock()

        engine.close()
        if isFinishing {
            completeFinish(utterance: current)
        } else if let currentSource {
            openEngine(currentSource, utterance: current)
        }
    }

    // MARK: - Audio thread

    private func handleChunk(_ chunk: [Float], tap: UInt64) {
        guard !chunk.isEmpty else { return }
        var rms: Float = 0
        vDSP_rmsqv(chunk, 1, &rms, vDSP_Length(chunk.count))
        let level = Self.visibleLevel(rms: rms)

        lock.lock()
        guard isRecording, generation == tap else {
            lock.unlock()
            return
        }
        samples.append(contentsOf: chunk)
        // The buffer landing past the deadline holds the audio up to it. Stopping on
        // a timer instead would lose the part of the tail still in the tap's buffer.
        var tailElapsed = false
        if let tailDeadline, DispatchTime.now() >= tailDeadline {
            self.tailDeadline = nil
            tailElapsed = true
        }
        let current = utterance
        lock.unlock()

        onLevel?(level)
        onChunk?(chunk)
        if tailElapsed {
            queue.async { self.completeFinish(utterance: current) }
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
}

/// `AudioInputEngine` over a real `AVAudioEngine`. On macOS there is no
/// `AVAudioSession`, so device selection goes through CoreAudio directly.
final class AVAudioInputEngine: AudioInputEngine, @unchecked Sendable {

    private static let targetSampleRate: Double = 16_000

    private let targetFormat: AVAudioFormat = {
        // Force-unwrap: this format is always valid on supported hardware.
        AVAudioFormat(commonFormat: .pcmFormatFloat32,
                      sampleRate: AVAudioInputEngine.targetSampleRate,
                      channels: 1,
                      interleaved: false)!
    }()

    /// A fresh instance per open — coreaudiod releases the input aggregate cleanly
    /// when the old one is dropped.
    private var engine: AVAudioEngine?
    /// Kept so closing never goes through the `inputNode` getter, which raises an
    /// unrecoverable exception once the device is gone.
    private var tappedInput: AVAudioInputNode?
    private var configObserver: NSObjectProtocol?

    func hasInputDevice() -> Bool {
        MicrophoneCapture.defaultInputDeviceID() != nil
    }

    func warmUp() {
        guard hasInputDevice() else { return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        // Any input primes CoreAudio, so a Bluetooth default is never woken for this:
        // it would drop the user's headphones to call quality at every launch.
        let source = CaptureSource(deviceUID: nil, avoidBluetooth: true)
        guard (try? Self.select(source, on: input)) != nil else { return }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { _, _ in }
        engine.prepare()
        try? engine.start()
        input.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
    }

    func open(_ source: CaptureSource,
              onChunk: @escaping @Sendable ([Float]) -> Void,
              onConfigurationChange: @escaping @Sendable () -> Void) throws {
        // Touching `inputNode` with no input device raises an unrecoverable
        // Objective-C exception — guard first.
        guard hasInputDevice() else { throw MicrophoneCapture.CaptureError.noInputDevice }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        try Self.select(source, on: input)

        // Tap in the hardware's native format (often 48 kHz stereo). Installing a
        // tap whose format differs from the node's own raises a runtime trap.
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw MicrophoneCapture.CaptureError.invalidFormat
        }

        // One converter per tap, reused across its buffers (see `convert` for the
        // `.noDataNow` contract) and rebuilt with the engine when the format changes.
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw MicrophoneCapture.CaptureError.invalidFormat
        }
        // Highest-quality rate conversion: 48 kHz → 16 kHz is the single
        // unavoidable DSP step of every utterance, so let Apple spend the
        // cycles instead of leaving the converter at its default profile.
        converter.sampleRateConverterQuality = .max
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering

        let targetFormat = self.targetFormat
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            guard let chunk = Self.convert(buffer, with: converter, to: targetFormat) else { return }
            onChunk(chunk)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw MicrophoneCapture.CaptureError.engineStartFailed
        }

        self.engine = engine
        tappedInput = input
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { _ in
            onConfigurationChange()
        }
    }

    func close() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
        }
        configObserver = nil
        tappedInput?.removeTap(onBus: 0)
        tappedInput = nil
        engine?.stop()
        engine?.reset()
        engine = nil
    }

    private static func convert(_ buffer: AVAudioPCMBuffer,
                                with converter: AVAudioConverter,
                                to targetFormat: AVAudioFormat) -> [Float]? {
        guard buffer.frameLength > 0 else { return nil }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return nil
        }

        // The converter is reused across buffers, so the input block must report
        // `.noDataNow` after handing over its one buffer — NEVER `.endOfStream`,
        // which latches the converter into a terminal state that yields zero
        // samples on every subsequent utterance.
        var provided = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if provided {
                inputStatus.pointee = .noDataNow
                return nil
            }
            provided = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let channel = output.floatChannelData?[0] else { return nil }

        let count = Int(output.frameLength)
        guard count > 0 else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: count))
    }

    /// Points the input node at what `source` resolves to. Left alone, the node
    /// follows the system default.
    private static func select(_ source: CaptureSource, on input: AVAudioInputNode) throws {
        let decision = InputRoute.resolve(
            selectedUID: source.deviceUID,
            // An explicit selection needs neither read.
            inputs: source.deviceUID == nil ? MicrophoneCapture.routableInputs() : [],
            avoidBluetooth: source.avoidBluetooth,
            lidClosed: source.deviceUID == nil && MicrophoneCapture.isLidClosed())
        guard case .device(let uid) = decision else { return }
        guard let deviceID = MicrophoneCapture.deviceID(forUID: uid) else {
            throw MicrophoneCapture.CaptureError.selectedDeviceUnavailable
        }
        try MicrophoneCapture.setInputDevice(deviceID, on: input)
    }
}

extension MicrophoneCapture {

    // MARK: - Device presence

    fileprivate static func defaultInputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return status == noErr && deviceID != kAudioDeviceUnknown ? deviceID : nil
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

    fileprivate static func deviceID(forUID uid: String) -> AudioDeviceID? {
        allDeviceIDs().first { deviceUID(for: $0) == uid }
    }

    fileprivate static func setInputDevice(_ id: AudioDeviceID, on node: AVAudioInputNode) throws {
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

    /// The inputs as `InputRoute` sees them.
    static func routableInputs() -> [InputRoute.Input] {
        let defaultID = defaultInputDeviceID()
        return allDeviceIDs().filter(hasInputChannels).compactMap { id in
            guard let uid = deviceUID(for: id) else { return nil }
            return InputRoute.Input(uid: uid, transport: transport(for: id), isDefault: id == defaultID)
        }
    }

    private static func transport(for id: AudioDeviceID) -> InputRoute.Transport {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport) == noErr else {
            return .other
        }
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:
            return .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return .bluetooth
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate,
             kAudioDeviceTransportTypeAutoAggregate,
             kAudioDeviceTransportTypeContinuityCaptureWired,
             kAudioDeviceTransportTypeContinuityCaptureWireless:
            return .indirect
        default:
            return .other
        }
    }

    /// With the lid closed the built-in microphone is off in hardware though still
    /// listed. Machines without a lid have no such property, which reads as open.
    static func isLidClosed() -> Bool {
        let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard rootDomain != 0 else { return false }
        defer { IOObjectRelease(rootDomain) }
        let state = IORegistryEntryCreateCFProperty(
            rootDomain, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return state?.takeRetainedValue() as? Bool ?? false
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
