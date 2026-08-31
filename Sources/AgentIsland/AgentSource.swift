import Foundation

/// Which tool is running the session. Agents are not all Claude Code, and each vendor keeps its
/// session state somewhere different — but once discovered they are all just a pid in a terminal,
/// which is why jump and host detection stay vendor-agnostic.
enum Vendor: String {
    case claude, codex, cursor

    var label: String {
        switch self {
        case .claude: return "Claude"
        case .codex:  return "Codex"
        case .cursor: return "Cursor"
        }
    }
}

/// One vendor's way of answering "what sessions exist right now".
///
/// Discovery is the only genuinely per-vendor part. Everything downstream — the row, the jump,
/// the host resolution — works off a pid and a cwd, which every vendor has.
protocol AgentSource {
    var vendor: Vendor { get }
    /// True when this tool is present on the machine at all; absent tools cost nothing.
    var isAvailable: Bool { get }
    /// Sessions this vendor knows about, newest activity first. Called off the main actor.
    func discover() -> [Agent]
}

extension AgentSource {
    /// How far back a vendor's sessions stay interesting.
    ///
    /// Not uniform, because "session" means different things. A Claude Code session is a working
    /// session you return to for days. A Cursor session is one chat — 570 of them accumulate, 151
    /// inside ten days — so the same window that keeps Claude useful buries it in one-off
    /// questions. Shorter window, same intent: what could you plausibly still be working on.
    static var maxAge: TimeInterval { 10 * 24 * 3600 }
}

/// Turning a raw transcript entry into the words a human would recognise.
///
/// Every vendor injects synthetic context as if the user had typed it — Codex wraps environment
/// and plugin blurbs in XML-ish tags, Cursor prefixes a `<timestamp>` and a `<user_query>`. Left
/// alone these become the row's title, which is worse than no title: it is confidently wrong.
enum PromptText {
    /// Whole messages that are machinery, not instructions.
    private static let injected = ["<environment_context", "<recommended_plugins",
                                   "<skills_instructions", "<user_instructions",
                                   "<additional_data", "# AGENTS.md instructions"]

    private static let tag = try? NSRegularExpression(pattern: "</?[A-Za-z_][A-Za-z0-9_]*>")

    /// The first line the user actually wrote, or nil if the entry is entirely machinery.
    static func humanLine(_ raw: String) -> String? {
        let head = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // An explicit `<user_query>` says exactly where the human's words are. Prefer it over
        // any heuristic — the surrounding entry may open with injected context.
        if let open = head.range(of: "<user_query>") {
            let rest = head[open.upperBound...]
            let inner = rest.range(of: "</user_query>").map { String(rest[..<$0.lowerBound]) }
                ?? String(rest)
            if let line = usableLine(inner) { return line }
        }
        guard !injected.contains(where: { head.hasPrefix($0) }) else { return nil }
        return usableLine(head)
    }

    private static func usableLine(_ raw: String) -> String? {
        var body = raw
        // A `<timestamp>…</timestamp>` preamble describes the turn; it is never its content.
        if let end = body.range(of: "</timestamp>") { body = String(body[end.upperBound...]) }
        if let tag {
            body = tag.stringByReplacingMatches(
                in: body, range: NSRange(body.startIndex..., in: body), withTemplate: "\n")
        }
        let lines = body.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("<") }
        // A heading or a bare `USER:` label announces the prompt rather than being it — but if
        // that is all there is, it still names the session better than a bare id does.
        if let best = lines.first(where: { !$0.hasPrefix("#") && !isLabel($0) }) { return best }
        return lines.first.map {
            $0.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
        }.flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func isLabel(_ line: String) -> Bool {
        line.hasSuffix(":") && line.count <= 14
    }
}

/// Cases that have actually gone wrong: every one of these once produced a row titled with
/// machinery, a bare id, or nothing at all.
enum PromptCheck {
    static func run() -> Int32 {
        let cases: [(String, String?, String)] = [
            ("<timestamp>Mon</timestamp>\n<user_query>\nfix the leak\n</user_query>",
             "fix the leak", "cursor wraps the prompt in timestamp + user_query"),
            ("<additional_data><rules/></additional_data>\n<user_query>\nfix the leak\n</user_query>",
             "fix the leak", "an explicit user_query outranks a leading injected block"),
            ("<user_info>OS Version: darwin</user_info><user_query>fix the leak</user_query>",
             "fix the leak", "an unlisted wrapper must not donate its body"),
            ("<recommended_plugins>\nHere is a list of plugins that are available\n</recommended_plugins>",
             nil, "codex plugin blurb is machinery, not a prompt"),
            ("<environment_context>\ncwd: /tmp\n</environment_context>", nil, "environment blurb"),
            ("# AGENTS.md instructions for /Users/x", nil, "injected AGENTS.md preamble"),
            ("# Fix the login bug", "Fix the login bug", "a prompt that is only a heading"),
            ("USER:\nwhy is the pod crashlooping", "why is the pod crashlooping",
             "a bare USER: label announces the prompt"),
            ("<task> Act as a strict code reviewer", "Act as a strict code reviewer",
             "inline tag then real content"),
            ("Read these three runbooks in full:", "Read these three runbooks in full:",
             "a long line ending in a colon is content, not a label"),
        ]
        var failed = 0
        for (input, want, why) in cases {
            let got = PromptText.humanLine(input)
            if got != want {
                failed += 1
                FileHandle.standardError.write(
                    "FAIL \(why)\n  want: \(want ?? "nil")\n  got:  \(got ?? "nil")\n"
                        .data(using: .utf8)!)
            }
        }
        print("prompt extraction: \(cases.count - failed)/\(cases.count) cases")
        return failed == 0 ? 0 : 1
    }
}
