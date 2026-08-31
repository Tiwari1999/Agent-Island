import Foundation

/// Cursor sessions, from the per-session directories it keeps under `~/.cursor/chats`.
///
/// `<workspace-hash>/<session-uuid>/meta.json` carries a human title, the cwd and both
/// timestamps — more than Claude Code exposes, where the title has to be grepped out of a
/// transcript. `prompt_history.json` alongside it holds the instructions already extracted.
struct CursorSource: AgentSource {
    let vendor: Vendor = .cursor

    private var root: String { NSHomeDirectory() + "/.cursor/chats" }

    var isAvailable: Bool { FileManager.default.fileExists(atPath: root) }

    func discover() -> [Agent] {
        guard isAvailable else { return [] }
        // A chat, not a working session: keep two days rather than ten, and cap the result so a
        // burst of one-liners cannot bury the agents that matter.
        let cutoff = Date().addingTimeInterval(-2 * 24 * 3600)
        let cap = 12
        let fm = FileManager.default
        let running = Self.runningSessions()
        var agents: [Agent] = []

        // Hundreds of sessions accumulate here, so filter on directory mtime before reading
        // any JSON — the window discards almost all of them for the cost of a stat.
        guard let workspaces = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        for ws in workspaces {
            let wsPath = "\(root)/\(ws)"
            guard let sessions = try? fm.contentsOfDirectory(atPath: wsPath) else { continue }
            for session in sessions {
                let dir = "\(wsPath)/\(session)"
                guard let attrs = try? fm.attributesOfItem(atPath: dir),
                      let mtime = attrs[.modificationDate] as? Date, mtime > cutoff else { continue }
                guard let data = fm.contents(atPath: "\(dir)/meta.json"),
                      let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                // A session with no conversation is an empty shell Cursor left behind.
                guard (meta["hasConversation"] as? Bool) ?? false else { continue }

                let cwd = meta["cwd"] as? String
                let updated = (meta["updatedAtMs"] as? NSNumber).map {
                    Date(timeIntervalSince1970: $0.doubleValue / 1000)
                } ?? mtime
                let live = cwd.flatMap { running[$0] }

                agents.append(Agent(
                    sessionId: session,
                    name: nil,
                    cwd: cwd,
                    state: live != nil ? "idle" : nil,
                    status: nil,
                    pid: live,
                    vendor: .cursor,
                    lastActiveOverride: updated,
                    titleOverride: meta["title"] as? String,
                    promptOverride: Self.lastPrompt(dir: dir)))
            }
        }
        return agents
            .sorted { ($0.lastActiveOverride ?? .distantPast) > ($1.lastActiveOverride ?? .distantPast) }
            .prefix(cap)
            .map { $0 }
    }

    /// prompt_history.json is a plain array of the instructions given, newest last.
    private static func lastPrompt(dir: String) -> String? {
        guard let data = FileManager.default.contents(atPath: "\(dir)/prompt_history.json"),
              let list = try? JSONSerialization.jsonObject(with: data) as? [String],
              var last = list.last, !last.isEmpty else { return nil }
        last = last.split(whereSeparator: \.isNewline).first.map(String.init) ?? last
        return last.count > 120 ? String(last.prefix(120)) + "…" : last
    }

    private static func runningSessions() -> [String: Int] {
        let pids = Shell.runSync("/usr/bin/pgrep", ["-f", "cursor-agent"])
            .split(whereSeparator: \.isNewline).compactMap { Int($0) }
        var byCwd: [String: Int] = [:]
        for pid in pids {
            let cwd = Shell.runSync("/bin/sh", ["-c",
                "lsof -a -p \(pid) -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cwd.isEmpty else { continue }
            if byCwd[cwd] == nil { byCwd[cwd] = pid } else { byCwd[cwd] = -1 }
        }
        return byCwd.filter { $0.value > 0 }
    }
}

/// Claude Code sessions. Wraps the CLI it already shipped with, so the behaviour is unchanged.
struct ClaudeSource: AgentSource {
    let vendor: Vendor = .claude

    var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: Shell.claude) }

    func discover() -> [Agent] {
        guard isAvailable else { return [] }
        let out = Shell.runSync(Shell.claude, ["agents", "--json", "--all"])
        guard let data = out.data(using: .utf8),
              let parsed = try? JSONDecoder().decode([Agent].self, from: data) else { return [] }
        return parsed
    }
}
