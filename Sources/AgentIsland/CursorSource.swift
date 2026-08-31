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
        Self.refreshIndex()
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
                // A directory that no longer exists cannot be opened or resumed, so the row
                // would be a dead end. Scratch directories are the common case.
                if let c = cwd, !fm.fileExists(atPath: c) { continue }
                let updated = (meta["updatedAtMs"] as? NSNumber).map {
                    Date(timeIntervalSince1970: $0.doubleValue / 1000)
                } ?? mtime
                let live = cwd.flatMap { running[$0] }
                let activity = Self.activity(sessionId: session)

                agents.append(Agent(
                    sessionId: session,
                    name: nil,
                    cwd: cwd,
                    state: activity.state ?? (live != nil ? "idle" : nil),
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

    /// Liveness, from the append-only transcript Cursor writes per session.
    ///
    /// Hooks are the official signal and are registered, but they only fire for interactive
    /// sessions — a headless run emits nothing, so hooks alone would leave those rows dead.
    /// The transcript is written either way: a recent append means the agent is working, and a
    /// trailing `turn_ended` means it has stopped and is waiting.
    ///
    /// Indexed once per refresh rather than probed per session: there are ~600 transcripts, and
    /// two subprocess spawns each took discovery from 0.6s to 4.3s.
    private static var index: [String: String] = [:]
    private static var indexedAt = Date.distantPast

    private static func refreshIndex() {
        guard Date().timeIntervalSince(indexedAt) > 30 else { return }
        indexedAt = Date()
        let root = NSHomeDirectory() + "/.cursor/projects"
        let listing = Shell.runSync("/usr/bin/find", [
            root, "-name", "*.jsonl", "-path", "*/agent-transcripts/*", "-newermt", "-2 days"])
        var map: [String: String] = [:]
        for path in listing.split(whereSeparator: \.isNewline).map(String.init) {
            // .../agent-transcripts/<session-uuid>/<file>.jsonl
            let session = (path as NSString).deletingLastPathComponent
            map[(session as NSString).lastPathComponent] = path
        }
        if !map.isEmpty { index = map }
    }

    private static func activity(sessionId: String) -> (state: String?, at: Date?) {
        guard let path = index[sessionId],
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date else { return (nil, nil) }
        // Only read the file at all when it was touched recently; a stale one is idle by
        // definition and its contents cannot change that.
        guard Date().timeIntervalSince(mtime) < 30 else { return ("idle", mtime) }
        let ended = lastLine(path).contains("turn_ended")
        return (ended ? "idle" : "busy", mtime)
    }

    /// Read the tail in-process rather than spawning `tail`.
    private static func lastLine(_ path: String) -> String {
        guard let h = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let back = UInt64(min(size, 2048))
        try? h.seek(toOffset: size - back)
        let data = h.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
        // Full-command match is required here: cursor-agent execs a versioned node binary, so
        // the process name is "node". It matches a single process, unlike codex.
        let pids = Shell.runSync("/usr/bin/pgrep", ["-f", "cursor-agent"])
            .split(whereSeparator: \.isNewline).compactMap { Int($0) }
        return Cwd.map(pids: pids)
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
