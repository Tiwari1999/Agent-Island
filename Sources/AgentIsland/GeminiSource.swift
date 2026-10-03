import Foundation

/// Gemini CLI sessions: `~/.gemini/tmp/<project>/chats/session-*.jsonl`, metadata line then one line
/// per message plus `{"$set":…}` patches; the directory is in `<project>/.project_root`.
struct GeminiSource: AgentSource {
    let vendor: Vendor = .gemini

    private var root: String { Home.path + "/.gemini/tmp" }

    var isAvailable: Bool { FileManager.default.fileExists(atPath: root) }

    func discover() -> [Agent] {
        guard isAvailable else { return [] }
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-Self.maxAge)

        // Subagents log one level deeper, under their parent's id; only the top level is a chat.
        var dated: [(path: String, mtime: Date, cwd: String?)] = []
        for project in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
            let chats = root + "/" + project + "/chats"
            guard let files = try? fm.contentsOfDirectory(atPath: chats) else { continue }
            let cwd = (try? String(contentsOfFile: root + "/" + project + "/.project_root",
                                   encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            for f in files where f.hasPrefix("session-") && f.hasSuffix(".jsonl") {
                let path = chats + "/" + f
                guard let m = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                      m > cutoff else { continue }
                dated.append((path, m, cwd))
            }
        }
        let files = dated.sorted { $0.mtime > $1.mtime }.prefix(200)

        var agents: [Agent] = []
        var claimed = Set<Int>()
        let running = Cwd.map(pids: Proc.leaves(Proc.pids(named: ["gemini"])))
        for (path, mtime, cwd) in files {
            if let c = cwd, !fm.fileExists(atPath: c) { continue }
            let log = Self.log(path: path, mtime: mtime)
            guard let id = log.sessionId, log.kind != "subagent" else { continue }
            var live = cwd.flatMap { running[$0] }
            if let p = live, claimed.contains(p) { live = nil }
            if let p = live { claimed.insert(p) }
            // A log with no prompt in it is a session opened and closed without a word.
            guard log.firstPrompt != nil || live != nil else { continue }
            agents.append(Agent(
                sessionId: id,
                name: log.summary,
                cwd: cwd,
                state: live == nil ? nil : (CodexSource.working(since: mtime) ? "busy" : "idle"),
                status: nil,
                pid: live,
                vendor: .gemini,
                lastActiveOverride: mtime,
                titleOverride: log.firstPrompt
                    ?? cwd.map { ($0 as NSString).lastPathComponent + " session" },
                promptOverride: log.lastPrompt,
                contextPctOverride: log.contextPct))
        }
        let keep = Set(files.map(\.path))
        Self.cache = Self.cache.filter { keep.contains($0.key) }
        return agents
    }

    struct Log: Equatable {
        var sessionId: String?
        var kind: String?
        var summary: String?
        var firstPrompt: String?
        var lastPrompt: String?
        var contextPct: Int?
    }

    private static var cache: [String: (mtime: Date, value: Log)] = [:]

    /// Append-only, so an unchanged mtime means unchanged answers. The opening prompt is near
    /// the top and the newest prompt and token count near the bottom.
    static func log(path: String, mtime: Date) -> Log {
        if let hit = cache[path], hit.mtime == mtime { return hit.value }
        let head = Tail.head(path: path, bytes: 256 * 1024)
        let tail = Tail.read(path: path, bytes: 2 * 1024 * 1024)
        var r = parse(head)
        let t = parse(tail)
        r.lastPrompt = t.lastPrompt ?? r.lastPrompt
        r.contextPct = t.contextPct ?? r.contextPct
        r.summary = t.summary ?? r.summary
        r.sessionId = t.sessionId ?? r.sessionId
        cache[path] = (mtime, r)
        return r
    }

    static func parse(_ text: String) -> Log {
        var r = Log()
        for line in text.split(whereSeparator: \.isNewline) {
            guard line.contains("\"sessionId\"") || line.contains("\"type\":\"user\"")
                    || line.contains("\"tokens\"") || line.contains("\"$set\""),
                  let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            // Metadata is the first line, and `$set` patches it later (summary, resumed id).
            let meta = obj["$set"] as? [String: Any] ?? (obj["projectHash"] != nil ? obj : [:])
            if let id = meta["sessionId"] as? String { r.sessionId = id }
            if let k = meta["kind"] as? String { r.kind = k }
            if let s = meta["summary"] as? String, !s.isEmpty { r.summary = s }
            switch obj["type"] as? String {
            case "user":
                // displayContent is what was typed; content has @-file expansions inlined.
                // Tool results are logged as user messages too, with no text part.
                guard let t = partText(obj["displayContent"]) ?? partText(obj["content"]),
                      let line = PromptText.humanLine(t) else { continue }
                if r.firstPrompt == nil { r.firstPrompt = String(line.prefix(60)) }
                r.lastPrompt = line.count > 120 ? String(line.prefix(120)) + "…" : line
            case "gemini":
                // ponytail: every current Gemini model has a 1M window; read the model when one doesn't.
                if let tok = obj["tokens"] as? [String: Any],
                   let input = (tok["input"] as? NSNumber)?.doubleValue, input > 0 {
                    r.contextPct = min(99, Int(input / 1_048_576 * 100))
                }
            default: break
            }
        }
        return r
    }

    /// A PartListUnion: a bare string, or an array of parts of which only `text` ones count.
    private static func partText(_ content: Any?) -> String? {
        if let s = content as? String { return s.isEmpty ? nil : s }
        let joined = (content as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
            .joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }
}
