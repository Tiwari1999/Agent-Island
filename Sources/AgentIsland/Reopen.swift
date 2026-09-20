import AppKit

/// Which terminal a closed session is reopened in. A Warp user wants Warp, not the macOS default.
enum ReopenTarget: String, CaseIterable {
    case warp, terminal
    var label: String { self == .warp ? "Warp" : "Terminal" }
    static var warpInstalled: Bool { FileManager.default.fileExists(atPath: "/Applications/Warp.app") }
    /// Default to the terminal the user actually has — nearly every session here runs in Warp.
    static var preferred: ReopenTarget { warpInstalled ? .warp : .terminal }
}

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

        // Reopen in Warp when the user chose it: a launch configuration is the one handle that
        // runs a command in Warp (verified — warp://launch executes the exec), so the chat comes
        // back where the user works instead of the macOS default Terminal.
        if agent.remoteHost == nil, Prefs.shared.reopenIn == .warp, let dir = cwd, !dir.isEmpty,
           FileManager.default.fileExists(atPath: dir), runInWarp(cmd, cwd: dir) {
            note("\(agent.vendor.label) resuming in Warp")
            return true
        }

        // Terminal.app runs the command outright (a timed ⌘V could land in the wrong window).
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
        // Only open Warp when Warp is what the user reopens in and actually has. Firing this
        // unconditionally launched Warp for someone who had chosen Terminal, or never installed
        // it, when the only thing left to do was hand them the command.
        if Prefs.shared.reopenIn == .warp, ReopenTarget.warpInstalled,
           let u = URL(string: "warp://action/new_tab") { NSWorkspace.shared.open(u) }
        note(copied)
        return true
    }

    private static var lastRun: (id: String, at: Date)?

    /// Reopen in Warp through a tab configuration. A launch config opens a whole new window; a tab
    /// config (`warp://tab_config/<name>`) opens a new tab in the CURRENT window and still runs its
    /// commands. One reused file; the id is already validID-gated, cwd/command are TOML-quoted.
    private static func runInWarp(_ cmd: String, cwd: String) -> Bool {
        let dir = Home.path + "/.warp/tab_configs"
        let name = "agentisland-reopen"
        let toml = """
        name = "\(name)"

        [[panes]]
        id = "main"
        type = "terminal"
        directory = \(tomlQuote(cwd))
        commands = [\(tomlQuote(cmd))]
        """
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard (try? toml.write(toFile: "\(dir)/\(name).toml", atomically: true, encoding: .utf8)) != nil,
              let url = URL(string: "warp://tab_config/\(name)") else { return false }
        NSWorkspace.shared.open(url)
        return true
    }

    private static func tomlQuote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                 .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

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
