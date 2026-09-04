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
        // The model's own summary beats the raw parameters: three identical `python3 - <<'PY'`
        // lines are indistinguishable in a notch, three descriptions are not.
        let described = HookStream.activity(from: [
            "tool_name": "Bash",
            "tool_input": ["command": "python3 - <<'PY'\nimport json",
                           "description": "Check hook payloads for description fields"]])?.detail
        if described != "Check hook payloads for description fields" {
            failed += 1
            FileHandle.standardError.write(
                "FAIL description should win over command: \(described ?? "nil")\n"
                    .data(using: .utf8)!)
        }
        let noDesc = HookStream.activity(from: [
            "tool_name": "Bash", "tool_input": ["command": "git status"]])?.detail
        if noDesc != "git status" {
            failed += 1
            FileHandle.standardError.write("FAIL without a description the command shows\n"
                                           .data(using: .utf8)!)
        }
        // A deferred question must still say what is being asked.
        let asked = HookStream.activity(from: [
            "tool_name": "AskUserQuestion",
            "tool_input": ["questions": [["question": "How do you want to unblock it?",
                                          "options": [["label": "a"], ["label": "b"]]]]]])?.detail
        if asked != "How do you want to unblock it?" {
            failed += 1
            FileHandle.standardError.write(
                "FAIL question text should be the status: \(asked ?? "nil")\n"
                    .data(using: .utf8)!)
        }
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
        // Risk flags are a highlight, never a verdict — but a missed destructive pattern is a
        // real failure, so the canonical ones are pinned.
        let riskCases: [(String, [String])] = [
            ("sudo rm -rf /tmp/x && git push --force", ["recursive delete", "runs as root", "forced", "publishes commits"]),
            ("echo hello", []),
            ("kubectl delete ns prod", ["deletes k8s resources"]),
        ]
        for (cmd, want) in riskCases {
            let got = ApprovalContext.riskFlags(in: cmd)
            if got != want {
                failed += 1
                FileHandle.standardError.write("FAIL risk \(cmd): \(got)\n".data(using: .utf8)!)
            }
        }
        if HookStream.fullText(tool: "Bash", input: ["command": "a\nb"]) != "a\nb"
            || HookStream.fullText(tool: "Edit",
                                   input: ["file_path": "/x.swift", "new_string": "let a=1"]) != "/x.swift\n\nlet a=1"
            || HookStream.fullText(tool: "X", input: "notdict") != nil {
            failed += 1
            FileHandle.standardError.write("FAIL fullText shapes\n".data(using: .utf8)!)
        }
        // The bar's motion is driven by this mapping; a wrong kind is a wrong status.
        func row(_ tool: String?, waiting: Bool = false, working: Bool = true) -> AgentRow {
            AgentRow(agent: Agent(sessionId: "k", name: nil, cwd: nil,
                                  state: working ? "busy" : "idle", status: nil, pid: 1),
                     // active mirrors `working`: a live hook state that says otherwise
                     // outranks the vendor's own state, which is the point of the field.
                     live: LiveState(tool: tool, detail: nil, waiting: waiting, active: working))
        }
        let kinds: [(AgentRow, WorkKind, String)] = [
            (row("Edit"), .writing, "editing a file"),
            (row("Bash"), .running, "running a command"),
            (row("Grep"), .reading, "reading the codebase"),
            (row("WebSearch"), .searching, "searching the web"),
            (row("Task"), .delegating, "delegating to a subagent"),
            (row(nil), .thinking, "between tool calls"),
            (row("Bash", waiting: true), .waiting, "waiting outranks any tool"),
            (row("Bash", working: false), .idle, "not working is idle"),
        ]
        for (r, want, why) in kinds where r.workKind != want {
            failed += 1
            FileHandle.standardError.write(
                "FAIL kind \(why): got \(r.workKind), want \(want)\n".data(using: .utf8)!)
        }
        // The transcript's mtime moves when a turn *ends* too (and for metadata writes that are
        // not conversation at all), so the hook's verdict has to win.
        let busy = Agent(sessionId: "w", name: nil, cwd: nil, state: "busy", status: nil, pid: 1)
        let working: [(AgentRow, Bool, String)] = [
            (AgentRow(agent: busy, live: LiveState(active: false)), false,
             "a hook that says the turn ended beats a fresh mtime"),
            (AgentRow(agent: busy, live: LiveState(active: true)), true,
             "mid-turn stays working"),
            (AgentRow(agent: busy, live: nil), true,
             "no hook data falls back to the vendor's own state"),
            (AgentRow(agent: Agent(sessionId: "i", name: nil, cwd: nil, state: "idle",
                                   status: nil, pid: 1), live: nil), false,
             "idle without hooks stays idle"),
        ]
        // A stale "active" cuts two ways, and the transcript is the disambiguator: still
        // growing means a long generation between tool calls (shown idle mid-run before);
        // gone quiet means a turn that ended without its Stop.
        let staleLive = LiveState(tool: "Bash", detail: "x", waiting: false,
                                  at: Date(timeIntervalSinceNow: -200), active: true)
        let generating = AgentRow(agent: busy, live: staleLive)
        if !generating.isWorking {
            failed += 1
            FileHandle.standardError.write("FAIL an open turn with a live transcript is work\n"
                                           .data(using: .utf8)!)
        }
        // What ends an open turn is the process going away, not the transcript going quiet:
        // a long generation writes nothing for minutes and is still very much working.
        let abandoned = AgentRow(agent: Agent(sessionId: "a", name: nil, cwd: nil,
                                              state: "idle", status: nil, pid: 999_999),
                                 live: staleLive)
        if abandoned.isWorking {
            failed += 1
            FileHandle.standardError.write("FAIL an open turn on a dead process is not work\n"
                                           .data(using: .utf8)!)
        }
        let quietButAlive = AgentRow(agent: Agent(sessionId: "q", name: nil, cwd: nil,
                                                  state: "idle", status: nil, pid: 1),
                                     live: staleLive)
        if !quietButAlive.isWorking {
            failed += 1
            FileHandle.standardError.write("FAIL a long generation still counts as work\n"
                                           .data(using: .utf8)!)
        }
        // An informational notification is news, not a question.
        for kind in ["auth_success", "auth_failure", "update_success"] where !HookStream.informational(kind) {
            failed += 1
            FileHandle.standardError.write("FAIL \(kind) should not read as an ask\n"
                                           .data(using: .utf8)!)
        }
        if HookStream.informational("permission_request") {
            failed += 1
            FileHandle.standardError.write("FAIL a real ask must not be filtered away\n"
                                           .data(using: .utf8)!)
        }
        if abandoned.activity != nil {
            failed += 1
            FileHandle.standardError.write("FAIL finished work must not read as activity\n"
                                           .data(using: .utf8)!)
        }
        // Ordering is a product rule, not an accident of timestamps: needs-you, then
        // working, then idle — whatever lastActive or the frozen order says.
        let idleRow = AgentRow(agent: Agent(sessionId: "t1", name: nil, cwd: nil,
                                            state: "idle", status: nil, pid: 1), live: nil)
        let workRow = AgentRow(agent: busy, live: LiveState(active: true))
        var waitRow = AgentRow(agent: busy, live: LiveState(waiting: true, active: true))
        waitRow.live?.waiting = true
        let tiers = [(AgentStore.tier(waitRow), 0, "a blocked agent outranks everything"),
                     (AgentStore.tier(workRow), 1, "working sits between"),
                     (AgentStore.tier(idleRow), 2, "idle sinks to the bottom")]
        // kill -9 mid-tool sends no Stop and no PostToolUse, so the open-tool flag is the
        // only thing still claiming work. It must not outlive the process it describes.
        let killedMidTool = AgentRow(
            agent: Agent(sessionId: "k", name: nil, cwd: nil, state: "busy", status: nil,
                         pid: 999_999),
            live: LiveState(at: Date(timeIntervalSinceNow: -600), active: true, inTool: true))
        if killedMidTool.isWorking {
            failed += 1
            FileHandle.standardError.write("FAIL an open tool on a dead pid is not work\n"
                                           .data(using: .utf8)!)
        }
        if killedMidTool.waiting {
            failed += 1
            FileHandle.standardError.write("FAIL a dead pid cannot be waiting on you\n"
                                           .data(using: .utf8)!)
        }
        let diedMidTool = AgentRow(agent: busy,
                                   live: LiveState(at: Date(timeIntervalSinceNow: -300),
                                                   active: false, inTool: true))
        if diedMidTool.isWorking {
            failed += 1
            FileHandle.standardError.write("FAIL a dead session with a stuck tool is not work\n"
                                           .data(using: .utf8)!)
        }
        for (got, want, why) in tiers where got != want {
            failed += 1
            FileHandle.standardError.write("FAIL tier \(why)\n".data(using: .utf8)!)
        }
        for (r, want, why) in working where r.isWorking != want {
            failed += 1
            FileHandle.standardError.write("FAIL working \(why)\n".data(using: .utf8)!)
        }
        // Tool-call parsing, against fixtures rather than whatever happens to be on disk:
        // a normal call, a failure, one still running, a subagent, and an MCP namespace.
        func ev(_ id: String, _ name: String, _ input: String, _ ts: String) -> String {
            """
            {"timestamp":"\(ts)","message":{"content":[{"type":"tool_use","id":"\(id)",\
            "name":"\(name)","input":\(input)}]}}
            """
        }
        func res(_ id: String, _ text: String, _ err: Bool, _ ts: String) -> String {
            """
            {"timestamp":"\(ts)","message":{"content":[{"type":"tool_result",\
            "tool_use_id":"\(id)","is_error":\(err),"content":"\(text)"}]}}
            """
        }
        let fixture = [
            ev("a", "Bash", #"{"description":"Run the suite","command":"swift test"}"#,
               "2026-09-03T10:00:00.000Z"),
            res("a", "all green", false, "2026-09-03T10:00:04.000Z"),
            ev("b", "Bash", #"{"description":"Check config","command":"cat x"}"#,
               "2026-09-03T10:01:00.000Z"),
            res("b", "no such file", true, "2026-09-03T10:01:01.000Z"),
            ev("c", "Read", #"{"file_path":"/a/b/AgentStore.swift"}"#, "2026-09-03T10:02:00.000Z"),
            res("c", "", false, "2026-09-03T10:02:00.500Z"),
            ev("d", "Agent", #"{"description":"Review the diff","subagent_type":"code-reviewer"}"#,
               "2026-09-03T10:03:00.000Z"),
            ev("e", "mcp__claude-in-chrome__computer", #"{"description":"Click login"}"#,
               "2026-09-03T10:04:00.000Z"),
            res("e", "clicked", false, "2026-09-03T10:04:02.000Z"),
            ev("f", "mcp__harbor-prod__get_job_live_results", #"{"description":"Poll a job"}"#,
               "2026-09-03T10:05:00.000Z"),
            res("f", "running", false, "2026-09-03T10:05:01.000Z"),
        ].joined(separator: "\n")

        let parsed = ToolCalls.parse(fixture)
        let tc: [(Bool, String)] = [
            (parsed.count == 6, "every call is found"),
            (parsed.first?.tool == "get_job_live_results",
             "an MCP leaf keeps its own underscores"),
            (parsed.first(where: { $0.id.hasPrefix("e#") })?.tool == "computer",
             "the MCP namespace is stripped"),
            (parsed.first(where: { $0.id.hasPrefix("a#") })?.why == "Run the suite",
             "the description is the why, not the command"),
            (parsed.first(where: { $0.id.hasPrefix("a#") })?.response == "all green", "the response is kept"),
            (parsed.first(where: { $0.id.hasPrefix("b#") })?.isError == true, "a failure is marked"),
            (parsed.first(where: { $0.id.hasPrefix("c#") })?.why == "AgentStore.swift",
             "a file tool falls back to its filename"),
            (parsed.first(where: { $0.id.hasPrefix("d#") })?.running == true,
             "a call with no result is still running"),
            (parsed.first(where: { $0.id.hasPrefix("d#") })?.subagentKind == "code-reviewer",
             "a subagent launch is recognised"),
            (parsed.first(where: { $0.id.hasPrefix("a#") })?.duration == "4s", "duration comes from the pair"),
            (parsed.first(where: { $0.id.hasPrefix("c#") })?.duration == "0.5s", "sub-second keeps a decimal"),
        ]
        for (ok, why) in tc where !ok {
            failed += 1
            FileHandle.standardError.write("FAIL toolcall \(why)\n".data(using: .utf8)!)
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
        print("pure-logic checks: "
              + "\(cases.count + hooks.count + kinds.count + working.count + 12 - failed)/"
              + "\(cases.count + hooks.count + kinds.count + working.count + 12) cases")
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
        // Lossy on purpose: a window that starts mid-sequence used to decode to nothing at
        // all, blanking the whole read rather than one character.
        var text = String(decoding: data, as: UTF8.self)
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
        // Lossy on purpose: a window that starts mid-sequence used to decode to nothing at
        // all, blanking the whole read rather than one character.
        var text = String(decoding: data, as: UTF8.self)
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

/// The syscall layer, validated against the live process table — a wrong struct offset here
/// reads garbage paths, which is worse than a crash.
enum ProcCheck {
    static func run() -> Int32 {
        var failed = 0
        func fail(_ m: String) { failed += 1
            FileHandle.standardError.write("FAIL \(m)\n".data(using: .utf8)!) }

        let me = Int(getpid())
        if Proc.cwd(pid: me) != FileManager.default.currentDirectoryPath {
            fail("cwd(self) != FileManager cwd: \(Proc.cwd(pid: me) ?? "nil")")
        }
        guard let ae = Proc.argsEnv(pid: me) else { fail("argsEnv(self) nil"); return 1 }
        if ae.env["HOME"] != NSHomeDirectory() { fail("env HOME mismatch") }
        if !(ae.argv.first ?? "").contains("AgentIsland") { fail("argv[0] = \(ae.argv)") }
        let table = Proc.all()
        if table[Int32(me)] == nil { fail("own pid missing from table") }
        if table.count < 50 { fail("implausibly small table: \(table.count)") }
        print("proc checks: \(failed == 0 ? "ok" : "\(failed) failed") "
              + "(\(table.count) processes, self comm=\(table[Int32(me)] ?? "?"))")
        return failed == 0 ? 0 : 1
    }
}
