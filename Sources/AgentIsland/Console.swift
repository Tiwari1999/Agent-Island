import Foundation

/// One line of the console: what the agent said, or what it ran.
struct ConsoleEntry: Identifiable {
    enum Kind {
        case said(String)                       // assistant prose, rendered as markdown
        case ran(tool: String, why: String, seconds: Double?, failed: Bool)
    }
    let id: String
    let at: Date?
    let kind: Kind

    var isSaid: Bool { if case .said = kind { return true }; return false }
}

/// A run of consecutive tool calls, or one thing the agent said.
struct ConsoleChunk: Identifiable {
    enum Kind { case said(String, Date?); case ran([ConsoleEntry]) }
    let id: String
    let kind: Kind
}

/// The agent's recent output: one tail of the transcript, parsed only when someone is looking.
/// Measured at ~5 ms on a 198 MB transcript, because only the end is ever read.
enum Console {
    /// Enough for the last several exchanges without turning one long reply into the whole feed.
    private static let window: UInt64 = 512 * 1024
    private static var cache: [String: (mtime: Date, feed: [ConsoleEntry])] = [:]
    private static let lock = NSLock()

    static func retain(_ ids: Set<String>) {
        lock.lock(); cache = cache.filter { ids.contains($0.key) }; lock.unlock()
    }

    /// Oldest first, so the newest lands at the bottom where a console puts it.
    static func recent(session: String, cwd: String?, limit: Int = 40) -> [ConsoleEntry] {
        guard let path = Transcript.path(sessionId: session, cwd: cwd) else { return [] }
        let mtime = ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate]
                     as? Date) ?? .distantPast
        lock.lock()
        if let hit = cache[session], hit.mtime == mtime {
            lock.unlock()
            return Array(hit.feed.suffix(limit))
        }
        lock.unlock()

        let feed = parse(Tail.read(path: path, bytes: window))
        lock.lock(); cache[session] = (mtime, feed); lock.unlock()
        return Array(feed.suffix(limit))
    }

    /// Assistant prose and tool calls in order. A result is paired only for duration and
    /// failure — output is not shown, since one 400 KB Read would bury everything around it.
    static func parse(_ text: String) -> [ConsoleEntry] {
        var out: [ConsoleEntry] = []
        var pending: [String: Int] = [:]        // tool_use id → index in `out`
        var i = 0

        for line in text.split(whereSeparator: \.isNewline) {
            guard line.contains("\"assistant\"") || line.contains("tool_result"),
                  let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let msg = obj["message"] as? [String: Any],
                  let blocks = msg["content"] as? [[String: Any]]
            else { continue }
            let at = (obj["timestamp"] as? String).flatMap(Self.date)

            for b in blocks {
                switch b["type"] as? String {
                case "text":
                    guard let t = (b["text"] as? String)?
                            .trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty
                    else { continue }
                    i += 1
                    out.append(ConsoleEntry(id: "s\(i)", at: at, kind: .said(t)))
                case "tool_use":
                    guard let id = b["id"] as? String, let name = b["name"] as? String
                    else { continue }
                    i += 1
                    let input = b["input"] as? [String: Any] ?? [:]
                    pending[id] = out.count
                    out.append(ConsoleEntry(id: "t\(i)", at: at,
                                            kind: .ran(tool: ToolCalls.short(name),
                                                       why: ToolCalls.why(tool: name, input: input),
                                                       seconds: nil, failed: false)))
                case "tool_result":
                    guard let id = b["tool_use_id"] as? String, let at = pending[id],
                          case let .ran(tool, why, _, _) = out[at].kind else { continue }
                    pending[id] = nil
                    let secs = out[at].at.flatMap { start in
                        (obj["timestamp"] as? String).flatMap(Self.date)
                            .map { $0.timeIntervalSince(start) }
                    }
                    out[at] = ConsoleEntry(id: out[at].id, at: out[at].at,
                                           kind: .ran(tool: tool, why: why, seconds: secs,
                                                      failed: b["is_error"] as? Bool ?? false))
                default: continue
                }
            }
        }
        return out
    }

    /// Consecutive tool calls collapse into one block, so ten greps read as a single aside
    /// rather than ten competing lines.
    static func group(_ feed: [ConsoleEntry]) -> [ConsoleChunk] {
        var out: [ConsoleChunk] = []
        var run: [ConsoleEntry] = []
        func flush() {
            guard !run.isEmpty else { return }
            out.append(ConsoleChunk(id: "r" + (run.first?.id ?? ""), kind: .ran(run)))
            run = []
        }
        for e in feed {
            switch e.kind {
            case .said(let t): flush(); out.append(ConsoleChunk(id: e.id, kind: .said(t, e.at)))
            case .ran: run.append(e)
            }
        }
        flush()
        return out
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
