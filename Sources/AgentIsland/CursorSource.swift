import Foundation

/// Cursor sessions, from the per-session directories it keeps under `~/.cursor/chats`.
///
/// `<workspace-hash>/<session-uuid>/meta.json` carries a human title, the cwd and both
/// timestamps — more than Claude Code exposes, where the title has to be grepped out of a
/// transcript. `prompt_history.json` alongside it holds the instructions already extracted.
struct CursorSource: AgentSource {
    let vendor: Vendor = .cursor

    private var root: String { Home.path + "/.cursor/chats" }

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
                guard Self.isUserDriven(dir: dir) else { continue }
                let activity = Self.activity(sessionId: session)
                let prompt = Self.lastPrompt(dir: dir)
                // Cursor names a chat only once it has summarised it, so fall back to what the
                // user actually opened with — a bare UUID names nothing.
                let title = (meta["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? Self.firstInstruction(sessionId: session)
                    ?? prompt.map { String($0.prefix(52)) }
                    ?? cwd.map { ($0 as NSString).lastPathComponent + " chat" }
                let said = prompt ?? Self.lastInstruction(sessionId: session)

                agents.append(Agent(
                    sessionId: session,
                    name: nil,
                    cwd: cwd,
                    state: activity.state ?? (live != nil ? "idle" : nil),
                    status: nil,
                    pid: live,
                    vendor: .cursor,
                    lastActiveOverride: updated,
                    titleOverride: title,
                    // A one-turn chat would otherwise print the same sentence twice.
                    promptOverride: Self.echoes(said, title) ? nil : said))
            }
        }
        Self.retainText(Set(agents.map(\.sessionId)))
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
        let root = Home.path + "/.cursor/projects"
        let listing = Shell.runSync("/usr/bin/find", [
            // Wider than the two-day session window on purpose: a chat directory can be touched
            // long after its transcript was last written, and matching the windows left those
            // rows with no title and no activity.
            root, "-name", "*.jsonl", "-path", "*/agent-transcripts/*", "-newermt", "-30 days"])
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

    /// The first thing the user asked, read from the session transcript.
    ///
    /// A chat gets a `title` only once Cursor has summarised it, and `prompt_history.json` is
    /// not always written — leaving a bare UUID on the row, which names nothing.
    static func firstInstruction(sessionId: String) -> String? {
        instruction(sessionId: sessionId, fromEnd: false)
    }

    /// The most recent thing the user asked — the `You:` line, so a Cursor row carries the same
    /// three lines a Claude row does instead of a hole where its prompt should be.
    static func lastInstruction(sessionId: String) -> String? {
        instruction(sessionId: sessionId, fromEnd: true)
    }

    /// Both ends of a transcript, parsed once per file version.
    ///
    /// A transcript is append-only, so a file whose mtime has not moved cannot have new answers.
    /// Re-reading twelve of them on every refresh was the single largest cost in discovery.
    private static var textCache: [String: (mtime: Date, first: String?, last: String?)] = [:]

    static func retainText(_ ids: Set<String>) {
        textCache = textCache.filter { ids.contains($0.key) }
    }

    private static func instruction(sessionId: String, fromEnd: Bool) -> String? {
        guard let path = index[sessionId] else { return nil }
        let mtime = ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate]
                     as? Date) ?? .distantPast
        if let hit = textCache[sessionId], hit.mtime == mtime { return fromEnd ? hit.last : hit.first }
        let first = scan(path: path, fromEnd: false)
        let last = scan(path: path, fromEnd: true)
        textCache[sessionId] = (mtime, first, last)
        return fromEnd ? last : first
    }

    private static func scan(path: String, fromEnd: Bool) -> String? {
        // Only the end that is being asked for: a transcript's middle never holds either answer.
        let text = fromEnd ? Tail.read(path: path, bytes: 256 * 1024)
                           : Tail.head(path: path, bytes: 256 * 1024)
        guard !text.isEmpty else { return nil }
        let all = text.split(whereSeparator: \.isNewline)
        let window = fromEnd ? Array(all.suffix(80).reversed()) : Array(all.prefix(40))
        for line in window {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let role = (obj["role"] as? String) ?? (obj["type"] as? String) ?? ""
            guard role.contains("user") else { continue }
            guard let body = Self.plainText(obj), !body.isEmpty else { continue }
            guard let one = PromptText.humanLine(body) else { continue }
            return one.count > 52 ? String(one.prefix(52)) + "…" : one
        }
        return nil
    }

    /// Whether two labels say the same thing, allowing for one being the truncated form.
    static func echoes(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        func key(_ s: String) -> String {
            String(s.replacingOccurrences(of: "…", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines).prefix(40)).lowercased()
        }
        return key(a) == key(b)
    }


    /// Pull readable text out of an entry, whose content may be a string or an array of blocks.
    private static func plainText(_ obj: [String: Any]) -> String? {
        if let t = obj["text"] as? String { return t }
        let message = obj["message"] as? [String: Any] ?? obj
        if let t = message["content"] as? String { return t }
        if let blocks = message["content"] as? [[String: Any]] {
            let text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .joined(separator: " ")
            return text.isEmpty ? nil : text
        }
        return nil
    }

    /// prompt_history.json is a plain array of the instructions given, newest last.
    private static func lastPrompt(dir: String) -> String? {
        guard let data = FileManager.default.contents(atPath: "\(dir)/prompt_history.json"),
              let list = try? JSONSerialization.jsonObject(with: data) as? [String],
              var last = list.last, !last.isEmpty else { return nil }
        last = last.split(whereSeparator: \.isNewline).first.map(String.init) ?? last
        return last.count > 120 ? String(last.prefix(120)) + "…" : last
    }

    /// Whether a human started this chat, rather than an agent spawning `cursor-agent -p`.
    ///
    /// Claude drives Cursor headlessly for its own subagent work, and those runs are effectively
    /// unlimited — 193 of the 198 sessions on this machine in a fortnight. Left in, they bury the
    /// user's own work in a panel that exists to show it.
    ///
    /// `prompt_history.json` is the only positive evidence of a person typing: the IDE writes it
    /// on submit. A title is not enough — Cursor summarises headless runs too — and a live
    /// process cannot be attributed to one session, because agents in a shared repo report the
    /// same working directory and none of them holds its transcript open.
    static func isUserDriven(dir: String) -> Bool {
        FileManager.default.fileExists(atPath: dir + "/prompt_history.json")
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
