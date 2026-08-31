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
            if let c = cwd, !FileManager.default.fileExists(atPath: c) { continue }
            let live = cwd.flatMap { running[$0] }
            let roll = Self.rollout(path: path, mtime: mtime)
            agents.append(Agent(
                sessionId: meta.id,
                name: nil,                       // Codex writes no title; the prompt becomes the label
                cwd: cwd,
                state: live != nil ? "idle" : nil,
                status: nil,
                pid: live,
                vendor: .codex,
                lastActiveOverride: mtime,
                titleOverride: roll.firstPrompt,
                promptOverride: roll.lastPrompt,
                contextPctOverride: roll.contextPct))
        }
        Self.trimCache(keeping: Set(paths))
        return agents
    }

    /// Everything we need from one rollout file, read once.
    ///
    /// This was three `grep` subprocesses per file — 18 spawns per refresh at six sessions, and
    /// the single largest cost in discovery. A rollout is append-only, so a file whose mtime has
    /// not moved cannot have new answers: the cache makes a steady state nearly free.
    struct Rollout {
        var firstPrompt: String?
        var lastPrompt: String?
        var contextPct: Int?
    }

    private static var cache: [String: (mtime: Date, value: Rollout)] = [:]

    /// Rollout files outside the discovery window will never be read again.
    private static func trimCache(keeping paths: Set<String>) {
        cache = cache.filter { paths.contains($0.key) }
    }

    private static func rollout(path: String, mtime: Date) -> Rollout {
        if let hit = cache[path], hit.mtime == mtime { return hit.value }
        var r = Rollout()
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return r }

        var lastUsage: [String: Any]?
        for line in text.split(whereSeparator: \.isNewline) {
            // Cheap substring gate before paying for JSON on a line we do not want.
            let wantsPrompt = line.contains("\"user_message\"")
            let wantsUsage = line.contains("total_token_usage")
            guard wantsPrompt || wantsUsage,
                  let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let payload = obj["payload"] as? [String: Any] ?? obj
            if wantsPrompt, let t = promptText(payload) {
                if r.firstPrompt == nil { r.firstPrompt = String(t.prefix(60)) }
                r.lastPrompt = t.count > 120 ? String(t.prefix(120)) + "…" : t
            }
            if wantsUsage, let u = payload["total_token_usage"] as? [String: Any] { lastUsage = u }
        }
        if let u = lastUsage,
           let used = (u["total_tokens"] as? NSNumber)?.doubleValue
                   ?? (u["input_tokens"] as? NSNumber)?.doubleValue {
            // Codex does not publish the window size in the stream; 200k is its documented default.
            r.contextPct = min(99, Int(used / 200_000 * 100))
        }
        cache[path] = (mtime, r)
        return r
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

    private static func promptText(_ payload: [String: Any]) -> String? {
        guard var t = (payload["message"] as? String) ?? (payload["text"] as? String),
              !t.isEmpty else { return nil }
        t = t.split(whereSeparator: \.isNewline).first.map(String.init) ?? t
        return t
    }


    /// Map a running codex process to the directory it was started in, so a session in that
    /// directory can be jumped to. Matching on cwd is imperfect when two codex runs share a
    /// directory; the row simply becomes unjumpable rather than jumping somewhere wrong.
    private static func runningSessions() -> [String: Int] {
        // Exact name only. Matching the full command line pulled in 97 processes — every one
        // carrying "codex" anywhere in its environment, including unrelated agents — and each
        // cost an lsof call.
        let pids = Shell.runSync("/usr/bin/pgrep", ["-x", "codex"])
            .split(whereSeparator: \.isNewline).compactMap { Int($0) }
        return Cwd.map(pids: pids)
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
