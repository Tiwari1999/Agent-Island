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
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish(unavailable) }
        Shell.run(Shell.claude,
                  ["-p", prompt(item: item, session: session, cwd: cwd),
                   "--model", "haiku", "--strict-mcp-config", "--mcp-config", config],
                  cwd: dir) { out, code in
            let text = out.trimmingCharacters(in: .whitespacesAndNewlines)
            finish((code == 0 && !text.isEmpty) ? text : unavailable)
        }
    }

    private static let unavailable = "Could not reach an agent to explain this one."
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

        Explain in ONE paragraph of at most 60 words, plain language: what is actually being
        decided, and what the options mean in practice. No preamble, no markdown, no bullet
        characters, no headings, no blank lines.
        """
    }
}
