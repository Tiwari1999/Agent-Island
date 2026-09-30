import AppKit

/// Two cues, not a soundtrack. The reference app ships 28; a tool that pages you all day earns
/// exactly one sound for "you are blocking an agent" and one opt-in for "it finished".
enum Sounds {
    /// Ping is short and interrogative; Glass is soft and clearly not Ping, so the two never
    /// get confused when they land seconds apart. Both ship with macOS — nothing to bundle.
    private static let needsYouName = "Ping"
    private static let doneName = "Glass"

    /// `silenced` is read by the caller *before* it mutates state: once a card is up the island
    /// is by definition no longer hushed, so asking here would always answer false.
    static func needsYou(silenced: Bool) {
        guard Prefs.shared.soundNeedsYou, !Prefs.shared.snoozing, !silenced else { return }
        play(needsYouName)
    }

    static func done(silenced: Bool) {
        guard Prefs.shared.soundDone, !Prefs.shared.snoozing, !silenced else { return }
        play(doneName)
    }

    /// Off the main actor: both call sites fire mid shell-animation, and first-play decode of an
    /// aiff is enough to drop frames out of a 380ms spring.
    private static func play(_ name: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            NSSound(named: NSSound.Name(name))?.play()
        }
    }
}
