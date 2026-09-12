import AppKit

/// Getting back into a session that is not currently running.
///
/// A jump focuses a live terminal. Most sessions in the list are not live — they are history you
/// might want to continue — and each vendor resumes differently. Rather than leaving those rows
/// dead, run the vendor's own resume command in a terminal, in the session's directory.
enum Reopen {
    /// The command that continues this session, or nil when its id is not one we will run.
    static func command(for agent: Agent) -> String? {
        // Session ids come from parsed transcripts and directory names, not from us, and this
        // string is now executed rather than copied — so reject odd ids instead of quoting them.
        if let host = agent.remoteHost {
            let sid = String(agent.sessionId.dropFirst(host.count + 1))
            guard Approvals.validID(sid), validHost(host) else { return nil }
            switch agent.vendor {
            case .claude: return "ssh -t \(host) claude --resume \(sid)"
            case .codex:  return "ssh -t \(host) codex resume \(sid)"
            case .cursor: return "ssh -t \(host) cursor-agent --resume \(sid)"
            }
        }
        guard Approvals.validID(agent.sessionId) else { return nil }
        switch agent.vendor {
        case .claude:
            // `attach` opens a session that is still *running*; a finished one has nothing to
            // attach to. --resume continues it in place — same id, same transcript, no fork.
            if agent.pid != nil {
                return "\(Shell.claude) attach \(String(agent.sessionId.prefix(8)))"
            }
            return "\(Shell.claude) --resume \(agent.sessionId)"
        case .codex:
            return "\(Shell.codex) resume \(agent.sessionId)"
        case .cursor:
            return "\(Shell.cursorAgent) --resume \(agent.sessionId)"
        }
    }

    /// Run the resume command in a terminal at the session's directory. The command also goes
    /// on the clipboard, so a remote session — which must resume on its own machine — is still
    /// one paste away. Returns a short line for the toast.
    /// Continue the session in a terminal, reporting through `note` once the attempt resolves.
    /// Returns false when the vendor or the id gives us nothing safe to run.
    @discardableResult
    static func run(_ agent: Agent, in cwd: String?, note: @escaping (String) -> Void) -> Bool {
        guard let cmd = command(for: agent) else { return false }
        // `do script` always opens a new window, so a second click while Terminal is still
        // coming up would resume the same transcript twice.
        if let last = lastRun, last.id == agent.sessionId,
           Date().timeIntervalSince(last.at) < 5 { return true }
        lastRun = (agent.sessionId, Date())
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)
        let copied = "\(agent.vendor.label) resume command copied"

        // Warp is not scriptable, its launch-config URL does not execute, and a timed ⌘V can
        // land in whatever the user was working in. Terminal.app runs it outright.
        if agent.remoteHost == nil, let dir = cwd, !dir.isEmpty, scriptable(dir),
           FileManager.default.fileExists(atPath: dir) {
            let script = "cd \(shellQuote(dir)) && \(cmd)"
            // Async: the first run raises the Automation consent prompt, which would otherwise
            // freeze the island until the user answers it. Status is the only success signal —
            // osascript reports failure on stderr, which Shell discards.
            Shell.run("/usr/bin/osascript",
                      ["-e", "tell application \"Terminal\" to do script \(appleQuote(script))",
                       "-e", "tell application \"Terminal\" to activate"]) { _, status in
                Task { @MainActor in
                    note(status == 0 ? "\(agent.vendor.label) resuming in Terminal" : copied)
                }
            }
            return true
        }
        if let u = URL(string: "warp://action/new_tab") { NSWorkspace.shared.open(u) }
        note(copied)
        return true
    }

    private static var lastRun: (id: String, at: Date)?

    /// An ssh alias or hostname, which is interpolated into the command unquoted.
    private static func validHost(_ h: String) -> Bool {
        !h.isEmpty && h.count <= 255 && h.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".")
        }
    }

    /// An AppleScript string literal cannot span lines and has no escape for control characters,
    /// so a path containing one is handed to the clipboard instead of to `do script`.
    private static func scriptable(_ path: String) -> Bool {
        !path.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    private static func appleQuote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                 .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
