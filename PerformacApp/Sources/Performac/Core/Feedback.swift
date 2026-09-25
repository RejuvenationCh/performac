// Feedback.swift: the sound a move to the Trash makes.
//
// Finder's own sound, not a system alert: this is the same gesture, so it should sound like
// the same gesture. It ships inside CoreAudio.component rather than /System/Library/Sounds,
// which is why it cannot be reached by name.
//
// There is no preference for this. macOS already has one (System Settings › Sound › "Play
// user interface sound effects"), and a Mac app that invents its own copy of a system toggle
// is a Mac app that ignores the system.
import AppKit

@MainActor
enum Feedback {
    private static let finderTrash =
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport"
        + "/SystemSounds/finder/move to trash.aif"

    private static let sound: NSSound? = {
        // byReference: the file stays on disk rather than being read into memory
        NSSound(contentsOfFile: finderTrash, byReference: true) ?? NSSound(named: "Pop")
    }()

    /// Honours the system's interface-sounds setting, which is where a Mac user turns this off.
    static var uiSoundsEnabled: Bool {
        let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
        return global?["com.apple.sound.uiaudio.enabled"] as? Bool ?? true
    }

    /// Once per trash action, not once per file: fifty caches moving at once should sound
    /// like one gesture, not a machine gun.
    static func trashed() {
        guard uiSoundsEnabled, let s = sound else { return }
        if s.isPlaying { s.stop() }
        s.play()
    }
}
