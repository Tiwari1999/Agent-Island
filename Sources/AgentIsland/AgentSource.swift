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
        // Hook shapes that have blanked a row. Cursor's shell hooks carry no tool_name.
        let hooks: [([String: Any], String?, String)] = [
            (["hook_event_name": "beforeShellExecution", "command": "git log --oneline -5"],
             "git log --oneline -5", "cursor shell hook: command at the top level"),
            (["hook_event_name": "preToolUse", "tool_name": "Shell",
              "tool_input": ["command": "swift build"]],
             "swift build", "cursor preToolUse: normal tool_input"),
            (["hook_event_name": "PreToolUse", "tool_name": "Read",
              "tool_input": ["file_path": "/a/b/Views.swift"]],
             "Read Views.swift", "claude read"),
        ]
        for (obj, want, why) in hooks {
            let got = HookStream.activity(from: obj)?.detail
            if got != want {
                failed += 1
                FileHandle.standardError.write(
                    "FAIL \(why)\n  want: \(want ?? "nil")\n  got:  \(got ?? "nil")\n"
                        .data(using: .utf8)!)
            }
        }
        if HookStream.activity(from: ["hook_event_name": "Stop"]) != nil {
            failed += 1
            FileHandle.standardError.write(
                "FAIL an unreadable event must not erase the current activity\n".data(using: .utf8)!)
        }
        // Markdown block structure: a plan card that mis-parses renders one grey paragraph.
        let md = """
        # Title
        ## Steps
        - one
        - two
        ```
        code line
        ```
        ---
        tail **bold**
        """
        let blocks = MarkdownLite.blocks(md)
        let wantBlocks: [MarkdownLite.Block] = [
            .heading(1, "Title"), .heading(2, "Steps"), .bullet("one"), .bullet("two"),
            .code("code line"), .rule, .plain("tail **bold**"),
        ]
        if blocks != wantBlocks {
            failed += 1
            FileHandle.standardError.write("FAIL markdown blocks: \(blocks)\n".data(using: .utf8)!)
        }
        if MarkdownLite.blocks("```\nunclosed fence") != [.code("unclosed fence")] {
            failed += 1
            FileHandle.standardError.write("FAIL unclosed fence must still render\n".data(using: .utf8)!)
        }
        for (input, want, why) in cases {
            let got = PromptText.humanLine(input)
            if got != want {
                failed += 1
                FileHandle.standardError.write(
                    "FAIL \(why)\n  want: \(want ?? "nil")\n  got:  \(got ?? "nil")\n"
                        .data(using: .utf8)!)
            }
        }
        print("pure-logic checks: \(cases.count + hooks.count + 3 - failed)/"
              + "\(cases.count + hooks.count + 3) cases")
        return failed == 0 ? 0 : 1
    }
}

/// Reading the end of an append-only file without spawning anything.
///
/// `tail | grep | tail` costs four processes per session per refresh. At one agent that is
/// invisible; at a hundred it is four hundred process creations every cycle, which is the single
/// largest energy cost a notch app can have. It also removes a path interpolated into a shell.
enum Tail {
    static func read(path: String, bytes: UInt64) -> String {
        guard let h = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let truncated = size > bytes
        try? h.seek(toOffset: truncated ? size - bytes : 0)
        let data = (try? h.readToEnd()) ?? Data()
        var text = String(data: data, encoding: .utf8) ?? ""
        // Starting mid-file means the first line is a fragment, not JSON.
        if truncated, let first = text.firstIndex(where: \.isNewline) {
            text = String(text[text.index(after: first)...])
        }
        return text
    }

    /// The start of a file, for the entries a session opened with.
    static func head(path: String, bytes: Int) -> String {
        guard let h = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? h.close() }
        let data = h.readData(ofLength: bytes)
        var text = String(data: data, encoding: .utf8) ?? ""
        // The final line is probably cut in half; a half line is not parseable JSON.
        if data.count == bytes, let last = text.lastIndex(where: \.isNewline) {
            text = String(text[..<last])
        }
        return text
    }

    /// The last value of a `"key":"value"` pair, searching from the end.
    static func lastValue(of key: String, in text: String) -> String? {
        let needle = "\"\(key)\":\""
        guard let r = text.range(of: needle, options: .backwards) else { return nil }
        let rest = text[r.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        let value = String(rest[..<end])
        return value.isEmpty ? nil : value
    }
}

/// Where the vendors keep their data.
///
/// `NSHomeDirectory()` reads the password database and ignores `$HOME`, so without this seam a
/// load test cannot point discovery at a synthetic fleet — it would silently measure the real
/// machine instead, which is exactly what happened the first time. Production is unchanged: the
/// override is only set by the harness.
enum Home {
    static var path: String {
        ProcessInfo.processInfo.environment["AGENTISLAND_HOME"] ?? NSHomeDirectory()
    }
}
