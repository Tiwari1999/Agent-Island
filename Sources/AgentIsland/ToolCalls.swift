import Foundation

/// One tool call as a person would read it: what was called, why, and what came back.
struct ToolCall: Identifiable {
    let id: String
    let tool: String
    /// The agent's own words for what it is doing. Present on every Bash call and most others,
    /// and far more readable than the command — this is the headline, not the argument.
    let why: String
    let response: String?
    let isError: Bool
    /// No result yet: still executing.
    var running: Bool { response == nil && !isError }
    let seconds: Double?
    /// A subagent launch is an ordinary tool call that happens to have children.
    let subagentKind: String?
    var isAgent: Bool { subagentKind != nil }

    /// One line of intent, plus one of evidence when there is any. The row's height is summed
    /// from this, so a cell can never be shorter than what it draws.
    var lines: Int { (response.map { !$0.isEmpty } ?? false) || running ? 2 : 1 }

    var duration: String? {
        guard let s = seconds else { return nil }
        if s < 1 { return String(format: "%.1fs", s) }
        if s < 60 { return String(format: "%.0fs", s) }
        return String(format: "%.0fm %.0fs", (s / 60).rounded(.down), s.truncatingRemainder(dividingBy: 60))
    }
}

/// Reads recent tool calls out of a transcript. Nothing here runs on a refresh: a row is parsed
/// only when someone expands it, and an unchanged transcript is never parsed twice.
enum ToolCalls {
    /// Big enough that a single large tool result cannot push every call out of the window —
    /// one Read response can exceed 400KB on its own. Affordable only because this is lazy.
    private static let window: UInt64 = 2 * 1024 * 1024
    private static var cache: [String: (mtime: Date, calls: [ToolCall])] = [:]
    private static let lock = NSLock()

    static func retain(_ ids: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        cache = cache.filter { ids.contains($0.key) }
    }

    static func recent(session: String, cwd: String?, limit: Int = 5) -> [ToolCall] {
        guard let path = Transcript.path(sessionId: session, cwd: cwd) else { return [] }
        let mtime = ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate]
                     as? Date) ?? .distantPast
        lock.lock()
        if let hit = cache[session], hit.mtime == mtime {
            lock.unlock()
            return Array(hit.calls.prefix(limit))
        }
        lock.unlock()

        let calls = parse(Tail.read(path: path, bytes: window))
        lock.lock()
        cache[session] = (mtime, calls)
        lock.unlock()
        return Array(calls.prefix(limit))
    }

    /// Newest first. Pairs each tool_use with its tool_result; a use with no result is still
    /// running, which is the state most worth seeing.
    static func parse(_ text: String) -> [ToolCall] {
        var uses: [(id: String, tool: String, why: String, kind: String?, at: Date?)] = []
        var results: [String: (text: String, isError: Bool, at: Date?)] = [:]

        for line in text.split(whereSeparator: \.isNewline) {
            guard line.contains("tool_use") || line.contains("tool_result"),
                  let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let msg = obj["message"] as? [String: Any],
                  let blocks = msg["content"] as? [[String: Any]]
            else { continue }
            let at = (obj["timestamp"] as? String).flatMap(Self.date)

            for b in blocks {
                switch b["type"] as? String {
                case "tool_use":
                    guard let id = b["id"] as? String, let name = b["name"] as? String else { continue }
                    let input = b["input"] as? [String: Any] ?? [:]
                    uses.append((id, short(name), why(tool: name, input: input),
                                 input["subagent_type"] as? String, at))
                case "tool_result":
                    guard let id = b["tool_use_id"] as? String else { continue }
                    results[id] = (preview(b["content"]), b["is_error"] as? Bool ?? false, at)
                default: continue
                }
            }
        }

        // Identity is position-qualified: a transcript that replays or merges can carry the
        // same tool_use id twice, and two rows sharing an id makes SwiftUI's list identity
        // ambiguous — it animates and recycles the wrong one.
        return uses.enumerated().reversed().map { (i, u) in
            let r = results[u.id]
            return ToolCall(id: "\(u.id)#\(i)", tool: u.tool, why: u.why,
                            response: r?.text, isError: r?.isError ?? false,
                            seconds: (r?.at).flatMap { end in u.at.map { end.timeIntervalSince($0) } },
                            subagentKind: u.kind)
        }
    }

    // MARK: - reading a call the way a person would

    /// The agent's stated intent, in the field each tool happens to use. Falls back to the
    /// argument itself, which for a file tool is already the clearest possible description.
    private static func why(tool: String, input: [String: Any]) -> String {
        for key in ["description", "query", "prompt", "instructions"] {
            if let v = input[key] as? String, !v.isEmpty { return firstLine(v) }
        }
        if let p = input["file_path"] as? String ?? input["path"] as? String ?? input["notebook_path"] as? String {
            return (p as NSString).lastPathComponent
        }
        if let c = input["command"] as? String { return firstLine(c) }
        if let u = input["url"] as? String { return u }
        return ""
    }

    /// Strip the MCP prefix: "mcp__claude-in-chrome__computer" is a namespace, "computer" is a name.
    private static func short(_ tool: String) -> String {
        guard tool.hasPrefix("mcp__") else { return tool }
        return tool.split(separator: "_").last.map(String.init) ?? tool
    }

    /// The first line worth showing. Tool output is frequently minified source or a binary
    /// scan, so this is evidence rather than a headline — bounded hard and never wrapped.
    private static func preview(_ content: Any?) -> String {
        var text = ""
        if let s = content as? String { text = s }
        else if let blocks = content as? [[String: Any]] {
            text = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return firstLine(text)
    }

    private static func firstLine(_ s: String) -> String {
        let line = s.split(whereSeparator: \.isNewline)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.count > 120 ? String(t.prefix(120)) + "…" : t
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func date(_ s: String) -> Date? {
        iso.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}
