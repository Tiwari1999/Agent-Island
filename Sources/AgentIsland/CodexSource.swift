import Foundation

/// Codex sessions, from the rollout files it writes per session.
///
/// `~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl` — line one is a `session_meta` record
/// carrying the id, cwd and start time. There is no equivalent of `claude agents --json`, so
/// liveness is inferred from file mtime and from whether a codex process is still running in that
/// directory.
struct CodexSource: AgentSource {
    let vendor: Vendor = .codex

    private var root: String { NSHomeDirectory() + "/.codex/sessions" }

    var isAvailable: Bool { FileManager.default.fileExists(atPath: root) }

    func discover() -> [Agent] {
        guard isAvailable else { return [] }
        let cutoff = Date().addingTimeInterval(-Self.maxAge)

        // Only stat files inside the window; a year of rollouts is thousands of files.
        let listing = Shell.runSync("/bin/sh", ["-c",
            "find \(root) -name 'rollout-*.jsonl' -newermt '-10 days' 2>/dev/null | head -200"])
        let paths = listing.split(whereSeparator: \.isNewline).map(String.init)

        // `find -newermt` is unreliable across BSD/GNU, so verify the age from the file itself.
        var agents: [Agent] = []
        let running = Self.runningSessions()

        for path in paths {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let mtime = attrs[.modificationDate] as? Date, mtime > cutoff else { continue }
            guard let meta = Self.sessionMeta(path: path) else { continue }

            let cwd = meta.cwd
            let live = cwd.flatMap { running[$0] }
            agents.append(Agent(
                sessionId: meta.id,
                name: nil,                       // Codex writes no title; the prompt becomes the label
                cwd: cwd,
                state: live != nil ? "idle" : nil,
                status: nil,
                pid: live,
                vendor: .codex,
                lastActiveOverride: mtime,
                titleOverride: Self.firstPrompt(path: path),
                promptOverride: Self.lastPrompt(path: path)))
        }
        return agents
    }

    /// The first line of a rollout file is the session_meta record.
    private static func sessionMeta(path: String) -> (id: String, cwd: String?)? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let head = handle.readData(ofLength: 4096)
        guard let line = String(data: head, encoding: .utf8)?
                .split(whereSeparator: \.isNewline).first,
              let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["type"] as? String == "session_meta",
              let payload = obj["payload"] as? [String: Any],
              let id = payload["id"] as? String else { return nil }
        return (id, payload["cwd"] as? String)
    }

    /// Codex has no title field, so the opening instruction stands in for one.
    private static func firstPrompt(path: String) -> String? {
        let out = Shell.runSync("/bin/sh", ["-c",
            "grep -m1 '\"type\":\"user_message\"' \(shellQuote(path)) 2>/dev/null"])
        return summarise(out, limit: 60)
    }

    private static func lastPrompt(path: String) -> String? {
        let out = Shell.runSync("/bin/sh", ["-c",
            "grep '\"type\":\"user_message\"' \(shellQuote(path)) 2>/dev/null | tail -1"])
        return summarise(out, limit: 120)
    }

    private static func summarise(_ line: String, limit: Int) -> String? {
        guard let data = line.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let payload = obj["payload"] as? [String: Any] ?? obj
        guard var text = (payload["message"] as? String) ?? (payload["text"] as? String),
              !text.isEmpty else { return nil }
        text = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    /// Map a running codex process to the directory it was started in, so a session in that
    /// directory can be jumped to. Matching on cwd is imperfect when two codex runs share a
    /// directory; the row simply becomes unjumpable rather than jumping somewhere wrong.
    private static func runningSessions() -> [String: Int] {
        let pids = Shell.runSync("/usr/bin/pgrep", ["-x", "codex"])
            .split(whereSeparator: \.isNewline).compactMap { Int($0) }
        var byCwd: [String: Int] = [:]
        for pid in pids {
            let cwd = Shell.runSync("/bin/sh", ["-c",
                "lsof -a -p \(pid) -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cwd.isEmpty else { continue }
            if byCwd[cwd] == nil { byCwd[cwd] = pid } else { byCwd[cwd] = -1 }  // ambiguous
        }
        return byCwd.filter { $0.value > 0 }
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
