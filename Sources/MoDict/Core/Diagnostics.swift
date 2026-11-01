import Foundation
import os

/// Where MoDict logs. Numbers, labels and error descriptions only: never a
/// transcript, audio or a key (see `DictationTrace.summary`).
enum Log {
    static let dictation = Logger(subsystem: "com.modict.app", category: "dictation")
    static let model = Logger(subsystem: "com.modict.app", category: "model")
    static let app = Logger(subsystem: "com.modict.app", category: "app")
    static let signposter = OSSignposter(subsystem: "com.modict.app", category: "dictation")
}

/// Stage timings of one dictation, one line in the log when it ends. Read them with
/// `log stream --predicate 'subsystem == "com.modict.app"' --level info`; the stages
/// also show as signposts in Instruments.
struct DictationTrace {
    enum Outcome: String {
        case pasted, tap, cancelled, noSpeech = "no-speech", empty, timeout, failed
        case microphoneFailed = "microphone-failed"
        case secureInput = "secure-input"
        case noAccessibility = "no-accessibility"
        case pasteFailed = "paste-failed"
    }

    enum Stage: String {
        case begin, hold, tail, gate, engine, paste
    }

    private let modelID: String
    private var last: TimeInterval
    private var stages: [(stage: Stage, milliseconds: Int)] = []
    /// When the key came up, from which the user starts waiting.
    private var released: TimeInterval?
    private var ended: TimeInterval?
    private var audioSeconds: Double?

    init(modelID: String, pressedAt: TimeInterval) {
        self.modelID = modelID
        self.last = pressedAt
    }

    /// Closes `stage` at `now`, and returns its name for the signpost.
    mutating func mark(_ stage: Stage, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        stages.append((stage, Int(((now - last) * 1000).rounded())))
        last = now
        if stage == .hold { released = now }
        ended = now
        Log.signposter.emitEvent("stage", id: .exclusive, "\(stage.rawValue, privacy: .public)")
    }

    mutating func noteAudio(seconds: Double) {
        audioSeconds = seconds
    }

    /// The log line. It takes no text as input, so a transcript has no way in.
    func summary(outcome: Outcome) -> String {
        var fields = ["outcome=\(outcome.rawValue)", "model=\(modelID)"]
        if let audioSeconds { fields.append("audio_s=" + String(format: "%.2f", audioSeconds)) }
        fields += stages.map { "\($0.stage.rawValue)_ms=\($0.milliseconds)" }
        if let released, let ended { fields.append("release_to_end_ms=\(Int(((ended - released) * 1000).rounded()))") }
        return fields.joined(separator: " ")
    }
}
