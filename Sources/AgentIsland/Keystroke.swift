import AppKit
import ApplicationServices

/// Pasting a line into an app that publishes no way to be written to.
///
/// Every other terminal the island knows takes a line through its own scripting interface, which
/// is precise and needs no permission. Warp publishes none, macOS refuses TIOCSTI, and Warp ships
/// no CLI or AppleScript dictionary — so for a session that is not mid-turn there is nothing left
/// but the keyboard.
///
/// Two keystrokes, never the text: posting a whole string drops characters into a TUI, and the
/// clipboard already holds the line exactly. The danger is the other half — ⌘V and Return landing
/// somewhere that is not the terminal — so nothing is posted until the intended app is verifiably
/// frontmost, and the attempt is abandoned rather than aimed at whatever else came forward.
enum Keystroke {
    /// Posting events needs Accessibility. Checked rather than assumed: without it CGEvent
    /// silently does nothing, which would read as the message vanishing.
    static var trusted: Bool { AXIsProcessTrusted() }

    /// Ask once, through the system prompt. Returns what the answer was at the time of asking.
    @discardableResult
    static func requestTrust() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Wait for `bundleID` to come forward, then paste and send. `done(false)` means nothing was
    /// posted at all — the line is still on the clipboard and the caller says so.
    static func pasteAndReturn(into bundleID: String, done: @escaping (Bool) -> Void) {
        guard trusted else { done(false); return }
        waitForFront(bundleID, tries: 15) { front in
            guard front else { done(false); return }
            // A last check on the same runloop turn as the post: the poll above proves it came
            // forward, this proves it has not gone away again.
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID,
                  let source = CGEventSource(stateID: .combinedSessionState)
            else { done(false); return }
            tap(source, key: 9, command: true)      // ⌘V
            tap(source, key: 36, command: false)    // Return
            done(true)
        }
    }

    /// Focus is asked for by opening a URL, which is asynchronous and can lose to a Space switch.
    /// 15 × 100ms is long enough for a cold Warp window and short enough not to strand the caller.
    private static func waitForFront(_ bundleID: String, tries: Int,
                                     done: @escaping (Bool) -> Void) {
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID {
            // Warp is frontmost but may still be raising the tab; the paste is worthless if it
            // lands before the pane has focus.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { done(true) }
            return
        }
        guard tries > 0 else { done(false); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            waitForFront(bundleID, tries: tries - 1, done: done)
        }
    }

    private static func tap(_ source: CGEventSource, key: CGKeyCode, command: Bool) {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else { return }
        if command { down.flags = .maskCommand; up.flags = .maskCommand }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
