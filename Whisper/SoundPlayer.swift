import AppKit

/// The start/stop chimes macOS Dictation plays, so toggling a recording here
/// sounds like the system feature this app stands in for.
enum SoundPlayer {
    /// Dictation's own chimes ship inside CoreAudio's SystemSounds bundle rather
    /// than /System/Library/Sounds, so there is no `NSSound(named:)` for them and
    /// they have to be loaded by path. Treated as optional throughout: a future
    /// macOS could move them, and a missing chime must not take the app down.
    private static let soundsPath =
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system"

    private static let begin = load("begin_record")
    private static let end = load("end_record")

    /// `byReference: false` keeps the ~44 KB decoded in memory, so a press chimes
    /// without touching the disk first.
    private static func load(_ name: String) -> NSSound? {
        NSSound(contentsOfFile: "\(soundsPath)/\(name).caf", byReference: false)
    }

    static func playStart() { play(begin) }
    static func playStop() { play(end) }

    private static func play(_ sound: NSSound?) {
        guard AppSettings.shared.soundFeedbackEnabled, let sound else { return }
        // `play()` is a no-op on an instance that is still playing, which a toggle
        // faster than the 0.45s chime would hit. Rewind so every press is heard.
        if sound.isPlaying { sound.stop() }
        sound.play()
    }
}
