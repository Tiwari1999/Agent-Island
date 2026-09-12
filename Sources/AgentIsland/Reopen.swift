import AppKit

/// Getting back into a session that is not currently running.
///
/// A jump focuses a live terminal. Most sessions in the list are not live — they are history you
/// might want to continue — and each vendor resumes differently. Rather than leaving those rows
/// dead, run the vendor's own resume command in a terminal, in the session's directory.
enum Reopen {
    /// The command that continues this session, or nil if the vendor has no resume path.
    static func command(for agent: Agent) -> String? {
        // A remote session resumes on its own machine; the host: prefix is ours, not the tool's.
        if let host = agent.remoteHost {
            let sid = String(agent.sessionId.dropFirst(host.count + 1))
            switch agent.vendor {
            case .claude: return "ssh -t \(host) claude --resume \(sid)"
            case .codex:  return "ssh -t \(host) codex resume \(sid)"
            case .cursor: return "ssh -t \(host) cursor-agent --resume \(sid)"
            }
        }
        switch agent.vendor {
        case .claude:
            // `attach` opens a session that is still *running*; a finished one has nothing to
            // attach to. --resume continues it in place — same id, same transcript, no fork.
            if agent.pid != nil {
                return "\(Shell.claude) attach \(String(agent.sessionId.prefix(8)))"
            }
            return "\(Shell.claude) --resume \(agent.sessionId)"
        case .codex:
            return "codex resume \(agent.sessionId)"
        case .cursor:
            return "cursor-agent --resume \(agent.sessionId)"
        }
    }

    /// Run the resume command in a terminal at the session's directory. The command also goes
    /// on the clipboard, so a remote session — which must resume on its own machine — is still
    /// one paste away. Returns a short line for the toast.
    @discardableResult
    static func run(_ agent: Agent, in cwd: String?) -> String? {
        guard let cmd = command(for: agent) else { return nil }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)

        // Warp is not scriptable, its launch-config URL does not execute, and a timed ⌘V can
        // land in whatever the user was working in. Terminal.app runs it outright.
        if agent.remoteHost == nil, let dir = cwd, !dir.isEmpty,
           FileManager.default.fileExists(atPath: dir) {
            let script = "cd \(shellQuote(dir)) && \(cmd)"
            _ = Shell.runSync("/usr/bin/osascript",
                              ["-e", "tell application \"Terminal\" to do script \(appleQuote(script))",
                               "-e", "tell application \"Terminal\" to activate"])
            return "\(agent.vendor.label) resuming in Terminal"
        }
        if let u = URL(string: "warp://action/new_tab") { NSWorkspace.shared.open(u) }
        return "\(agent.vendor.label) resume command copied"
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    private static func appleQuote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                 .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
