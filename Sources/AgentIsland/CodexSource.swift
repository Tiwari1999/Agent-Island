import Foundation

/// Codex sessions, from the rollout files it writes per session.
///
/// `~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl` — line one is a `session_meta` record
/// carrying the id, cwd and start time. There is no equivalent of `claude agents --json`, so
/// liveness is inferred from file mtime and from whether a codex process is still running in that
/// directory.
struct CodexSource: AgentSource {
    let vendor: Vendor = .codex

    private var root: String { Home.path + "/.codex/sessions" }

    var isAvailable: Bool { FileManager.default.fileExists(atPath: root) }

    func discover() -> [Agent] {
        guard isAvailable else { return [] }
        let cutoff = Date().addingTimeInterval(-Self.maxAge)

        // Walked in-process (this was a `find` spawn), windowed by mtime, capped to the
        // newest 200 — unsorted, a busy machine could drop the very session being watched.
        var dated: [(String, Date)] = []
        if let e = FileManager.default.enumerator(atPath: root) {
            for case let f as String in e where f.hasSuffix(".jsonl")
                && (f as NSString).lastPathComponent.hasPrefix("rollout-") {
                let path = root + "/" + f
                guard let m = (try? FileManager.default.attributesOfItem(atPath: path))?[
                    .modificationDate] as? Date, m > cutoff else { continue }
                dated.append((path, m))
            }
        }
        let paths = dated.sorted { $0.1 > $1.1 }.prefix(200).map(\.0)

        var agents: [Agent] = []
        var skipStale = 0, skipMeta = 0, skipCwd = 0
        var claimed = Set<Int>()
        var newestSeen: Date?
        let running = Self.runningSessions()

        for path in paths {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let mtime = attrs[.modificationDate] as? Date, mtime > cutoff
            else { skipStale += 1; continue }
            guard let meta = Self.sessionMeta(path: path) else { skipMeta += 1; continue }

            let cwd = meta.cwd
            if let c = cwd, !FileManager.default.fileExists(atPath: c) { skipCwd += 1; continue }
            // A pid belongs to one session: several rollouts share a directory, and handing the
            // same process to all of them made every one of them claim to be working.
            var live = cwd.flatMap { running[$0] }
            if let p = live, claimed.contains(p) { live = nil }
            if let p = live { claimed.insert(p) }
            let roll = Self.rollout(path: path, mtime: mtime)
            if Self.quota.fiveHourPct == nil || newestSeen == nil {
                newestSeen = mtime
                Self.quota = Quota(fiveHourPct: roll.limitPct, sevenDayPct: roll.weekPct,
                                   fiveHourResets: roll.limitResets)
            }
            agents.append(Agent(
                sessionId: meta.id,
                name: nil,                       // Codex writes no title; the prompt becomes the label
                cwd: cwd,
                // A live process means the session is open, not that it is working. Codex
                // appends to its rollout while it works, so recency is the evidence; without
                // this every open Codex tab claimed to be busy forever.
                state: live == nil ? nil
                    : (Date().timeIntervalSince(mtime) < 90 ? "busy" : "idle"),
                status: nil,
                pid: live,
                vendor: .codex,
                lastActiveOverride: mtime,
                titleOverride: roll.firstPrompt
                    ?? cwd.map { ($0 as NSString).lastPathComponent + " session" },
                promptOverride: roll.lastPrompt,
                contextPctOverride: roll.contextPct))
        }
        Self.trimCache(keeping: Set(paths))
        // Only worth a line when sessions were dropped: a vendor going quiet is the failure
        // that hides best, and this says which gate ate them.
        if skipStale + skipMeta + skipCwd > 0 {
            Diagnostics.log("codex: \(paths.count) paths -> \(agents.count) "
                + "(\(skipStale) stale, \(skipMeta) unparsable, \(skipCwd) dead cwd)")
        }
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
        /// Codex publishes its own quota beside the token counts: primary is the 5h window,
        /// secondary the weekly one — the same shape Claude's status line reports.
        var limitPct: Int?
        var weekPct: Int?
        var limitResets: Date?
    }

    /// The newest session's quota, for the panel and the resting bar.
    private(set) static var quota = Quota()

    private static var cache: [String: (mtime: Date, value: Rollout)] = [:]

    /// Rollout files outside the discovery window will never be read again.
    private static func trimCache(keeping paths: Set<String>) {
        cache = cache.filter { paths.contains($0.key) }
    }

    private static func rollout(path: String, mtime: Date) -> Rollout {
        if let hit = cache[path], hit.mtime == mtime { return hit.value }
        // Bounded reads rather than the whole file: the opening prompt is at the top, the newest
        // prompt and token count at the bottom. A single rollout entry can be large enough to push
        // the last token count out of a small tail, so the window is generous and we re-read in
        // full only when something is genuinely missing — which the mtime cache makes rare.
        func parse(_ text: String) -> Rollout {
            var r = Rollout()
            var lastUsage: [String: Any]?
            var window: Double?
            for line in text.split(whereSeparator: \.isNewline) {
                // Older rollouts logged a `user_message` event; newer ones record the turn as a
                // response_item whose content is a block array. Gate on either.
                let wantsPrompt = line.contains("\"user_message\"") || line.contains("\"input_text\"")
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
                if wantsUsage, let rl = payload["rate_limits"] as? [String: Any] {
                    if let p = rl["primary"] as? [String: Any] {
                        r.limitPct = (p["used_percent"] as? NSNumber)?.intValue
                        if let t = (p["resets_at"] as? NSNumber)?.doubleValue {
                            r.limitResets = Date(timeIntervalSince1970: t)
                        }
                    }
                    if let sec = rl["secondary"] as? [String: Any] {
                        r.weekPct = (sec["used_percent"] as? NSNumber)?.intValue
                    }
                }
                if wantsUsage {
                    // The accounting sits under `info`, and the cumulative total counts every turn
                    // ever sent — using it put every row at the compaction cliff. The last turn's
                    // input is the context that actually exists right now.
                    let info = (payload["info"] as? [String: Any]) ?? payload
                    if let u = info["last_token_usage"] as? [String: Any] { lastUsage = u }
                    if let w = (info["model_context_window"] as? NSNumber)?.doubleValue, w > 0 {
                        window = w
                    }
                }
            }
            if let u = lastUsage, let used = (u["input_tokens"] as? NSNumber)?.doubleValue {
                // Codex publishes the window it is actually using; 200k is only the fallback.
                r.contextPct = min(99, Int(used / (window ?? 200_000) * 100))
            }
            return r
        }

        var r = parse(Tail.head(path: path, bytes: 256 * 1024) + "\n"
                      + Tail.read(path: path, bytes: 2 * 1024 * 1024))
        if r.firstPrompt == nil || r.contextPct == nil,
           let whole = try? String(contentsOfFile: path, encoding: .utf8) {
            r = parse(whole)
        }
        cache[path] = (mtime, r)
        return r
    }

    /// The first line of a rollout file is the session_meta record.
    /// The first line, however long it is.
    ///
    /// This used to read a fixed 4 KB. Codex now embeds its instructions in `session_meta`, so
    /// the line is ~22 KB and every file silently failed to parse — the whole vendor vanished
    /// from the panel. Read to the newline, and cap it so a corrupt file cannot eat memory.
    private static func firstLine(path: String, cap: Int = 1 << 20) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var buf = Data()
        while buf.count < cap {
            let chunk = handle.readData(ofLength: 64 * 1024)
            if chunk.isEmpty { break }
            buf.append(chunk)
            if let nl = buf.firstIndex(of: 0x0A) {
                return String(data: buf.prefix(upTo: nl), encoding: .utf8)
            }
        }
        return buf.isEmpty ? nil : String(data: buf, encoding: .utf8)
    }

    private static func sessionMeta(path: String) -> (id: String, cwd: String?)? {
        guard let line = firstLine(path: path),
              let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["type"] as? String == "session_meta",
              let payload = obj["payload"] as? [String: Any],
              let id = payload["id"] as? String else { return nil }
        return (id, payload["cwd"] as? String)
    }

    /// The human's own words from one entry, whatever shape Codex wrote it in.
    ///
    /// Only `role: user` counts: the same block shape carries Codex's injected `developer`
    /// preamble, which would otherwise become the row's title.
    private static func promptText(_ payload: [String: Any]) -> String? {
        if let role = payload["role"] as? String, role != "user" { return nil }
        var raw = (payload["message"] as? String) ?? (payload["text"] as? String)
        if raw == nil, let blocks = payload["content"] as? [[String: Any]] {
            let joined = blocks.compactMap { b -> String? in
                guard let type = b["type"] as? String, type.contains("text") else { return nil }
                return b["text"] as? String
            }.joined(separator: " ")
            raw = joined.isEmpty ? nil : joined
        }
        guard let t = raw, !t.isEmpty else { return nil }
        return PromptText.humanLine(t)
    }


    /// Map a running codex process to the directory it was started in, so a session in that
    /// directory can be jumped to. Matching on cwd is imperfect when two codex runs share a
    /// directory; the row simply becomes unjumpable rather than jumping somewhere wrong.
    private static func runningSessions() -> [String: Int] {
        // Exact name only. Matching the full command line pulled in 97 processes — every one
        // carrying "codex" anywhere in its environment, including unrelated agents — and each
        // cost an lsof call.
        let pids = Proc.pids(comm: "codex")
        return Cwd.map(pids: pids)
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
