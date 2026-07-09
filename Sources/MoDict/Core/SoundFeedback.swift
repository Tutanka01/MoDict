import AppKit

/// Discreet audio and haptic cues for the dictation lifecycle. System sounds are
/// preloaded once and played at a low volume so a cue does not bleed into the
/// recording. Sounds are gated on `settings.playSounds`, haptics on
/// `settings.hapticFeedback`.
@MainActor
final class SoundFeedback {

    private let settings: SettingsStore

    private let startSound: NSSound?
    private let successSound: NSSound?
    private let failureSound: NSSound?

    init(settings: SettingsStore) {
        self.settings = settings
        self.startSound = SoundFeedback.loadSound(named: "Tink")
        self.successSound = SoundFeedback.loadSound(named: "Pop")
        self.failureSound = SoundFeedback.loadSound(named: "Basso")
    }

    func dictationStarted() {
        play(startSound)
        performHaptic(.alignment)
    }

    func dictationSucceeded() {
        play(successSound)
        performHaptic(.levelChange)
    }

    func dictationFailed() {
        play(failureSound)
    }

    // MARK: - Private

    private static func loadSound(named name: String) -> NSSound? {
        // `byReference: true` keeps the file on disk rather than in memory.
        let sound = NSSound(contentsOfFile: "/System/Library/Sounds/\(name).aiff", byReference: true)
        sound?.volume = 0.3
        return sound
    }

    private func play(_ sound: NSSound?) {
        guard settings.playSounds, let sound else { return }
        sound.stop()   // allow rapid re-triggering
        sound.play()
    }

    private func performHaptic(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        guard settings.hapticFeedback else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .default)
    }
}
