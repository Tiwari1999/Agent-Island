import AppKit

/// Getting back into a session that is not currently running.
///
/// A jump focuses a live terminal. Most sessions in the list are not live — they are history you
/// might want to continue — and each vendor resumes differently. Rather than leaving those rows
/// dead, hand over the exact command and open a terminal to paste it into.
enum Reopen {
    /// The command that continues this session, or nil if the vendor has no resume path.
    static func command(for agent: Agent) -> String? {
        switch agent.vendor {
        case .claude:
            // Only a session with a transcript can be attached; one stopped before its first
            // response must be respawned instead, and `attach` says so rather than working.
            return "\(Shell.claude) attach \(String(agent.sessionId.prefix(8)))"
        case .codex:
            return "codex resume \(agent.sessionId)"
        case .cursor:
            return "cursor-agent --resume \(agent.sessionId)"
        }
    }

    /// Put the command on the clipboard and open a terminal in the session's directory.
    /// Returns a short line describing what happened, for the toast.
    @discardableResult
    static func run(_ agent: Agent, in cwd: String?) -> String? {
        guard let cmd = command(for: agent) else { return nil }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)

        // Warp opens a tab in the right directory; the command is one paste away. Launching it
        // directly would mean choosing a shell and a profile on the user's behalf.
        if let dir = cwd, !dir.isEmpty {
            _ = Shell.runSync("/usr/bin/open", ["-a", "Warp", dir])
        } else if let u = URL(string: "warp://action/new_tab") {
            NSWorkspace.shared.open(u)
        }
        return "\(agent.vendor.label) resume command copied"
    }

    /// Open the session's project in Cursor — the natural destination for a Cursor chat, which
    /// belongs to a workspace rather than a terminal tab.
    @discardableResult
    static func openWorkspace(_ cwd: String) -> Bool {
        guard FileManager.default.fileExists(atPath: cwd) else { return false }
        let cursor = NSHomeDirectory() + "/.local/bin/cursor"
        if FileManager.default.isExecutableFile(atPath: cursor) {
            _ = Shell.runSync(cursor, [cwd])
            return true
        }
        return NSWorkspace.shared.open([URL(fileURLWithPath: cwd)],
                                       withApplicationAt: URL(fileURLWithPath: "/Applications/Cursor.app"),
                                       configuration: NSWorkspace.OpenConfiguration()) != nil
    }
}
