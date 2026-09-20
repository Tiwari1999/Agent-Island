import AppKit

/// Sending a line to the session's own terminal. Not synthetic typing: CGEvents drop characters
/// into a TUI and a timed ⌘V lands on whatever holds focus, so each terminal delivers its own.
enum TerminalWrite {
    /// Where a line waits for a session whose terminal takes no input. `agentisland-input.py`
    /// is a Stop hook: it picks the line up the moment the agent finishes its turn and hands it
    /// back as the reason to keep going.
    static let queueDir = "/tmp/agentisland-input"

    /// Leave a line for the Stop hook. Only worth offering while the agent is working — an idle
    /// one has no turn left to end, so the message would sit here unseen.
    @discardableResult
    static func queue(_ line: String, session: String) -> Bool {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 4096, Approvals.validID(session) else { return false }
        let fm = FileManager.default
        try? fm.createDirectory(atPath: queueDir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        // The hook hands this line to the model as an instruction; a directory we do not own is
        // one somebody else can put words in.
        guard TmpDir.ours(queueDir) else { return false }
        // A session that never ends another turn leaves its line here for ever. Nobody will
        // ever want a steer written yesterday delivered today, so drop those on the way past.
        if let stale = try? fm.contentsOfDirectory(atPath: queueDir) {
            for f in stale {
                let p = (queueDir as NSString).appendingPathComponent(f)
                let age = ((try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date)
                    .map { Date().timeIntervalSince($0) } ?? 0
                if age > 24 * 3600 { try? fm.removeItem(atPath: p) }
            }
        }
        let path = (queueDir as NSString).appendingPathComponent(session)
        return fm.createFile(atPath: path, contents: Data(text.utf8),
                             attributes: [.posixPermissions: 0o600])
    }

    /// Whether this host can be written to at all — Warp publishes no scripting interface.
    static func canWrite(_ host: HostTerminal) -> Bool {
        switch host {
        case .tmux, .iterm, .appleTerminal, .kitty, .wezterm: return true
        case .warp, .app, .degraded, .unknown: return false
        }
    }

    /// Send one line, as if typed and entered. False when the host or the text cannot take it.
    @discardableResult
    static func send(_ line: String, to host: HostTerminal) -> Bool {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        // A literal cannot hold control characters, and a multi-line payload is a different
        // feature — the caller sends one line at a time or not at all.
        guard !text.isEmpty, text.count <= 4096,
              !text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
        else { return false }

        switch host {
        case .tmux(let pane, _):
            let p = HostTerminal.tmuxSafe(pane)
            guard !p.isEmpty else { return false }
            // -l sends the text literally, so a reply containing "Enter" or "C-c" is typed
            // rather than interpreted. The Return is a separate, deliberate key.
            return ran("tmux send-keys -t '\(p)' -l \(shellQuoted(text)) "
                       + "&& tmux send-keys -t '\(p)' Enter")

        case .iterm(let session):
            let sid = HostTerminal.appleSafe(session.split(separator: ":").last.map(String.init) ?? session)
            guard !sid.isEmpty else { return false }
            // `write text` delivers the line and its Return to that session alone.
            return script("""
            tell application "iTerm"
              repeat with w in windows
                repeat with t in tabs of w
                  repeat with s in sessions of t
                    if id of s is "\(sid)" then
                      tell s to write text \(quoted(text))
                      return
                    end if
                  end repeat
                end repeat
              end repeat
            end tell
            """)

        case .appleTerminal(let session):
            let tty = HostTerminal.appleSafe(session)
            guard !tty.isEmpty else { return false }
            // `in t` is what keeps this in the session's own tab rather than opening a window.
            return script("""
            tell application "Terminal"
              repeat with w in windows
                repeat with t in tabs of w
                  if tty of t contains "\(tty)" then
                    do script \(quoted(text)) in t
                    return
                  end if
                end repeat
              end repeat
            end tell
            """)

        case .kitty(let window):
            let id = HostTerminal.appleSafe(window)
            guard !id.isEmpty else { return false }
            return ran("kitty @ send-text --match id:\(id) -- \(shellQuoted(text + "\n"))")

        case .wezterm(let pane):
            let id = HostTerminal.appleSafe(pane)
            guard !id.isEmpty else { return false }
            // --no-paste so the shell sees typed input rather than a bracketed paste.
            return ran("printf %s \(shellQuoted(text + "\n")) "
                       + "| wezterm cli send-text --pane-id \(id) --no-paste")
        case .warp, .app, .degraded, .unknown:
            return false
        }
    }

    /// runSync hands back stdout, not a status, so the command reports its own success.
    private static func ran(_ command: String) -> Bool {
        Shell.runSync("/bin/sh", ["-c", "\(command) 2>/dev/null && echo __ok__"])
            .contains("__ok__")
    }

    /// An AppleScript string literal. Only backslash and quote need escaping — control
    /// characters are rejected above, because a literal cannot span lines.
    private static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                 .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// In-process, so macOS attributes the Automation permission to this app rather than to a
    /// spawned osascript that already holds one.
    private static func script(_ source: String) -> Bool {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { Diagnostics.log("terminal write failed: \(error)"); return false }
        return true
    }
}
