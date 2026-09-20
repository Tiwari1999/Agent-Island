import Foundation

/// A plain-language read of the question on the card.
///
/// The agent that asked is blocked inside its own hook and cannot be asked anything, so this is
/// a separate headless `claude -p`: it never touches the asking session's transcript, and its
/// answer is never sent anywhere. MCP is switched off because the servers cost ~3s of startup
/// and an explanation needs no tools at all.
enum Explain {
    /// Its own directory, so the throwaway session lands in a project of its own rather than in
    /// whatever the island's cwd happens to be. `agentisland-hook.sh` drops events from here.
    static let dir = "/tmp/agentisland-explain"
    /// /tmp is a symlink to /private/tmp, so a hook reports the resolved path.
    static func isOwn(_ cwd: String) -> Bool { cwd == dir || cwd == "/private" + dir }

    private static var cache: [String: String] = [:]
    private static var inFlight = 0
    private static let lock = NSLock()

    static func cached(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return cache[key]
    }

    /// Ask once per question; the answer is the same every time and the call is not cheap.
    static func run(item: QuestionItem, session: String, cwd: String?,
                    done: @escaping (String) -> Void) {
        if let hit = cached(item.id) { done(hit); return }
        guard let config = prepare() else { done(unavailable); return }
        ask(engines: Engine.available, item: item, session: session, cwd: cwd,
            config: config, done: done)
    }

    /// Try each installed agent in turn. Being installed is not the same as being usable — a
    /// Claude binary with no subscription behind it fails in seconds — so a failure falls
    /// through to the next rather than to the user.
    private static func ask(engines: [Engine], item: QuestionItem, session: String, cwd: String?,
                            config: String, done: @escaping (String) -> Void) {
        guard let engine = engines.first else { done(unavailable); return }
        let rest = Array(engines.dropFirst())
        // The call has run between 10s and 18s. Shell.run has no deadline of its own, so a
        // hung CLI would leave the card saying "explaining…" for as long as the question lives.
        let settled = Settled()
        func finish(_ text: String) {
            guard settled.claim() else { return }
            // Only a real answer is kept. Caching the failure would turn one timeout into a
            // button that says "could not reach" for as long as the question is up.
            if text != unavailable { lock.lock(); cache[item.id] = text; lock.unlock() }
            release()
            done(text)
        }
        lock.lock(); inFlight += 1; lock.unlock()
        Shell.run(engine.path,
                  engine.args(prompt(item: item, session: session, cwd: cwd), config: config),
                  cwd: dir, timeout: timeout) { out, code in
            let text = engine.answer(from: out) ?? ""
            if code == 0, !text.isEmpty { finish(text); return }
            // This engine is installed but got us nothing. Release it and try the next.
            release()
            settled.reset()
            ask(engines: rest, item: item, session: session, cwd: cwd, config: config, done: done)
        }
    }

    /// The explanation as the card draws it: a lead sentence, and whatever was said about each
    /// option, keyed by the number the card already shows beside that option.
    ///
    /// An answer that never numbered anything is not discarded — it all becomes the lead, which
    /// is what the card used to show anyway.
    static func split(_ text: String) -> (lead: String, byIndex: [Int: String]) {
        var lead: [String] = []
        var byIndex: [Int: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if let mark = line.firstIndex(where: { $0 == "." || $0 == ")" }),
               let n = Int(line[line.startIndex..<mark]), (1...4).contains(n) {
                byIndex[n] = String(line[line.index(after: mark)...])
                    .trimmingCharacters(in: .whitespaces)
            } else if byIndex.isEmpty {
                lead.append(line)
            }
        }
        return (lead.joined(separator: " "), byIndex)
    }

    private static let unavailable = "Could not reach an agent to explain this one."
    /// Measured at 10-18s. The deadline is on the process itself, so a wedged CLI is killed
    /// rather than merely abandoned — abandoning it left the child writing a transcript that the
    /// sweep, now believing nothing was in flight, deleted underneath it.
    private static let timeout: TimeInterval = 45

    /// Whichever of the call and the deadline lands first owns the answer.
    private final class Settled: @unchecked Sendable {
        private let lock = NSLock()
        private var taken = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if taken { return false }
            taken = true; return true
        }
        /// Handing the question to the next engine means this one never answered after all.
        func reset() { lock.lock(); taken = false; lock.unlock() }
    }

    /// The agent CLIs that can answer this, in the order they are tried. The card is always a
    /// Claude one — only Claude Code raises an AskUserQuestion — but the machine it is on need
    /// not have a Claude subscription, and explaining is not work that cares who does it.
    enum Engine: String, CaseIterable {
        case claude, codex, cursor

        var path: String {
            switch self {
            case .claude: return Shell.claude
            case .codex:  return Shell.codex
            case .cursor: return Shell.cursorAgent
            }
        }

        /// Shell.resolve falls back to the bare name when it finds nothing, so ask the disk.
        var installed: Bool { FileManager.default.isExecutableFile(atPath: path) }
        static var available: [Engine] { allCases.filter(\.installed) }

        func args(_ prompt: String, config: String) -> [String] {
            switch self {
            case .claude:
                // MCP off: the servers cost ~3s of startup and this uses no tools.
                return ["-p", prompt, "--model", "haiku",
                        "--strict-mcp-config", "--mcp-config", config]
            case .codex:
                // The explain directory is not a git repo, and nothing here may touch the disk.
                return ["exec", "--skip-git-repo-check", "--sandbox", "read-only", "--json", prompt]
            case .cursor:
                return ["-p", "--trust", "--output-format", "text", prompt]
            }
        }

        /// Codex narrates its run on stdout; its answer is the last agent_message it emits.
        func answer(from out: String) -> String? {
            let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
            guard self == .codex else { return trimmed.isEmpty ? nil : trimmed }
            var last: String?
            for line in out.split(whereSeparator: \.isNewline) {
                guard line.hasPrefix("{"), let d = line.data(using: .utf8),
                      let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      o["type"] as? String == "item.completed",
                      let item = o["item"] as? [String: Any],
                      item["type"] as? String == "agent_message",
                      let text = item["text"] as? String else { continue }
                last = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return (last?.isEmpty ?? true) ? nil : last
        }
    }

    /// The directory and the empty MCP config the call needs. Returns the config path.
    private static func prepare() -> String? {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let config = dir + "/no-mcp.json"
        guard (try? #"{"mcpServers":{}}"#.write(toFile: config, atomically: true, encoding: .utf8))
                != nil else { return nil }
        return config
    }

    /// One call finishing while another is still running must not delete the transcript the
    /// running one is writing, so the sweep waits until nothing is in flight.
    private static func release() {
        lock.lock(); inFlight -= 1; let idle = inFlight <= 0; lock.unlock()
        if idle { sweep() }
    }

    /// Each call writes a ~50 KB transcript nobody will ever read. Left alone they pile up.
    private static func sweep() {
        let fm = FileManager.default
        for root in ["", "/private"] {
            let project = Home.path + "/.claude/projects/"
                + (root + dir).replacingOccurrences(of: "/", with: "-")
            guard let files = try? fm.contentsOfDirectory(atPath: project) else { continue }
            for f in files where f.hasSuffix(".jsonl") {
                try? fm.removeItem(atPath: project + "/" + f)
            }
        }
    }

    /// What the agent was doing is most of what makes an option mean anything, so a few lines of
    /// its own recent output lead the prompt.
    private static func prompt(item: QuestionItem, session: String, cwd: String?) -> String {
        var context: [String] = []
        for e in Console.recent(session: session, cwd: cwd, limit: 6) {
            switch e.kind {
            case .said(let t): context.append("- said: " + t.prefix(200).replacingOccurrences(
                of: "\n", with: " "))
            case .ran(let tool, let why, let cmd, _, _):
                context.append("- ran \(tool): " + (cmd ?? why).prefix(160))
            }
        }
        let options = item.options.prefix(4).enumerated().map { i, o in
            "\(i + 1). \(o.label)" + (o.detail.isEmpty ? "" : " — \(o.detail)")
        }
        return """
        You explain a choice to someone who is not an expert in this codebase.

        CONTEXT (what the agent just did):
        \(context.isEmpty ? "- nothing recorded" : context.joined(separator: "\n"))

        QUESTION: \(item.text)
        OPTIONS:
        \(options.joined(separator: "\n"))

        Reply in plain language, in exactly this shape and nothing else:

        First line: what is actually being decided, at most 20 words. No number in front of it.
        Then ONE line per option, in the same order, each starting with its number and a dot:
        what picking it actually means and when you would want it, at most 20 words.

        No preamble, no markdown, no bullet characters, no headings, no blank lines.
        """
    }
}
