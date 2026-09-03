import Combine
import Foundation

/// A permission request waiting on the user. The hook is blocked until this is answered.
struct Plan: Equatable {
    let markdown: String
    let at: Date
}

struct Approval: Identifiable, Equatable {
    let id: String            // ap_request_id the hook is polling for
    let session: String
    let tool: String
    let detail: String
    let deadline: Date        // hook gives up at this point; drop the card with it
    var plan: String?         // full Markdown when the ask is ExitPlanMode
    var cwd: String?          // where the session runs, for reading its transcript
    var fullInput: String?    // the complete ask, untruncated — a heredoc is unreviewable at one line
}

/// A multiple-choice question waiting on one click.
struct Question: Identifiable, Equatable {
    let id: String
    let session: String
    let header: String
    let text: String
    let options: [String]
    let deadline: Date
}

/// One agent's most recent hook-reported activity.
struct LiveState {
    var tool: String?
    var detail: String?
    var waiting = false
    var at = Date()
    /// The last few tool calls, newest last — an approval reads differently on a third retry.
    var trail: [String] = []
    /// Whether the agent is mid-turn. Hooks know this exactly; the transcript's mtime does not,
    /// because finishing a turn writes to the transcript too.
    var active = true
    /// A PreToolUse with no PostToolUse yet: the tool is still executing, however long it
    /// takes, and neither hooks nor the transcript will say anything more until it returns.
    var inTool = false
}

/// Tails the hook spool. Hooks append one JSON line per event; the file is the whole IPC.
final class HookStream: ObservableObject {
    static let spool = "/tmp/agentisland-events.jsonl"
    private static let replayBytes: UInt64 = 1 << 20
    /// Hooks are wired in, so silence from a session means idle, not unknown.
    static private(set) var covering = false

    @Published private(set) var live: [String: LiveState] = [:]
    /// Sessions that DIED rather than finished — a rate-limited run currently looks identical
    /// to a completed one, which is how a stalled fleet goes unnoticed.
    @Published private(set) var failures: [String: String] = [:]
    /// The last plan each session proposed, kept after approval so it can be re-read.
    @Published private(set) var plans: [String: Plan] = [:]
    /// (sessionId, message, needsInput) — fires once per attention-worthy transition.
    var onAttention: ((String, String, Bool) -> Void)?
    /// A tool is blocked waiting for the user to allow or deny it.
    var onApproval: ((Approval) -> Void)?
    /// An agent asked a multiple-choice question and is blocked on the answer.
    var onQuestion: ((Question) -> Void)?
    private var source: DispatchSourceFileSystemObject?
    /// Owned by the drain queue alone; never touched from the main thread.
    private var carried: [String: LiveState] = [:]

    /// session id -> the agent process that ran the hook. This is the only exact way to bind a
    /// session started without `--resume`, whose id appears nowhere in its own argv.
    @Published private(set) var pids: [String: Int] = [:]
    private var resolvedPPID: [String: Int] = [:]
    private var handle: FileHandle?
    private var offset: UInt64 = 0

    func start() {
        if !FileManager.default.fileExists(atPath: Self.spool) {
            FileManager.default.createFile(atPath: Self.spool, contents: nil)
        }
        guard let h = FileHandle(forReadingAtPath: Self.spool) else { return }
        handle = h
        Self.covering = Setup.hooksInstalled()
        // Replay the recent spool instead of starting blind: seeking to the end forgot every
        // pid binding and Stop on restart, so idle sessions fell back to the mtime guess and
        // showed as running until their next real event.
        let end = (try? h.seekToEnd()) ?? 0
        offset = end > Self.replayBytes ? end - Self.replayBytes : 0
        drain(replay: true)

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: h.fileDescriptor, eventMask: [.extend, .write, .delete, .rename],
            queue: DispatchQueue.global(qos: .utility))
        src.setEventHandler { [weak self] in
            guard let self else { return }
            // If the spool is deleted or replaced, hooks recreate it as a new inode; keep
            // watching the old fd and no event would ever arrive again. Reopen instead.
            if self.source?.data.contains(.delete) == true
                || self.source?.data.contains(.rename) == true {
                DispatchQueue.main.async { self.restart() }
            } else {
                self.drain()
            }
        }
        src.resume()
        source = src
    }

    private func restart() {
        source?.cancel(); source = nil
        try? handle?.close(); handle = nil
        offset = 0
        start()
    }

    private func drain(replay: Bool = false) {
        guard let h = handle else { return }
        h.seek(toFileOffset: offset)
        let data = h.readDataToEndOfFile()
        offset = h.offsetInFile
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }

        var updates: [String: LiveState] = [:]
        var planUpdates: [String: Plan] = [:]
        var pidUpdates: [String: Int] = [:]
        var attention: [(String, String, Bool)] = []
        var approvals: [Approval] = []
        var questions: [Question] = []
        var fails: [String: String] = [:]
        var revived: Set<String> = []
        for line in text.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  var obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
            else { continue }

            let stamp = (obj["ai_ts"] as? NSNumber).map {
                Date(timeIntervalSince1970: $0.doubleValue) }

            if let qid = obj["ap_question_id"] as? String,
               let opts = obj["options"] as? [String], !opts.isEmpty {
                questions.append(Question(
                    id: qid,
                    session: obj["session_id"] as? String ?? "",
                    header: obj["header"] as? String ?? "",
                    text: obj["question"] as? String ?? "",
                    options: opts,
                    deadline: Date().addingTimeInterval(43)))
                continue
            }

            // The event hook wraps its payload to carry the shell's parent, from which the
            // agent process is found by walking up the tree.
            if let ppid = obj["ai_ppid"] as? Int, let payload = obj["payload"] as? [String: Any] {
                if let sid = payload["session_id"] as? String, resolvedPPID[sid] != ppid {
                    resolvedPPID[sid] = ppid
                    if let agent = Proc.ancestor(of: ppid,
                                                 named: ["claude", "codex", "cursor-agent", "agent"]) {
                        pidUpdates[sid] = agent
                    }
                }
                obj = payload
            }
            // The permission hook wraps its payload so it can carry the id it is polling on.
            if let reqID = obj["ap_request_id"] as? String,
               let payload = obj["payload"] as? [String: Any] {
                let tool = payload["tool_name"] as? String ?? "tool"
                var plan: String?
                if tool == "ExitPlanMode",
                   let input = payload["tool_input"] as? [String: Any],
                   let p = input["plan"] as? String, !p.isEmpty { plan = p }
                let approval = Approval(
                    id: reqID,
                    session: payload["session_id"] as? String ?? "",
                    tool: tool,
                    detail: plan != nil ? "proposed a plan — review it here"
                        : Self.describe(tool: tool, input: payload["tool_input"]) ?? tool,
                    // A plan takes longer to read than a shell command does.
                    deadline: Date().addingTimeInterval(plan != nil ? 50 : 19),
                    plan: plan,
                    cwd: payload["cwd"] as? String,
                    fullInput: Self.fullText(tool: tool, input: payload["tool_input"]))
                approvals.append(approval)
                obj = payload
            }
            guard let session = obj["session_id"] as? String else { continue }
            let event = Self.canonical(obj["hook_event_name"] as? String ?? "")
            if obj["tool_name"] as? String == "ExitPlanMode",
               let input = obj["tool_input"] as? [String: Any],
               let p = input["plan"] as? String, !p.isEmpty {
                planUpdates[session] = Plan(markdown: p, at: Date())
            }
            var state = updates[session] ?? carried[session] ?? LiveState()
            state.at = stamp ?? (replay ? .distantPast : Date())

            switch event {
            case "PreToolUse", "PostToolUse":
                revived.insert(session)
                state.inTool = event == "PreToolUse"
                // Cursor's shell hooks name no tool and put the command at the top level, so
                // reading the fields literally blanked the row for the whole run. An event we
                // cannot read leaves the last known activity alone rather than erasing it.
                state.active = true
                // Blocked on a person, whichever path answers it.
                if obj["tool_name"] as? String == "AskUserQuestion" { state.waiting = true }
                if let a = Self.activity(from: obj) {
                    state.tool = a.tool
                    state.detail = a.detail
                    if event == "PreToolUse", let d = a.detail {
                        state.trail.append("\(a.tool ?? "tool"): \(d)")
                        if state.trail.count > 6 { state.trail.removeFirst() }
                    }
                }
                state.waiting = false
            case "Notification", "PermissionRequest":
                // `idle_prompt` just means the session finished its turn and is sitting at a
                // prompt — it fires constantly for every session and is not a request for you.
                // Only a genuine ask should raise a card, a badge, or a desktop alert.
                let kind = obj["notification_type"] as? String ?? ""
                let msg = obj["message"] as? String ?? "needs your input"
                if kind == "idle_prompt" {
                    // Sitting at a prompt is the clearest "not working" signal there is.
                    state.waiting = false
                    state.inTool = false
                    state.tool = nil
                    state.detail = nil
                    state.active = false
                } else {
                    state.waiting = true
                    state.detail = msg
                    attention.append((session, msg, true))
                }
            case "StopFailure":
                // StopFailure also fires on ordinary non-clean stops (an interrupt, for example)
                // with no error_type at all. Only a named failure — rate_limit, overloaded,
                // billing_error — actually means the session died.
                state.inTool = false        // however it stopped, no tool is running now
                guard let why = obj["error_type"] as? String, !why.isEmpty else {
                    state.waiting = false
                    break
                }
                fails[session] = why
                state.waiting = false
                state.active = false        // a dead session is not mid-turn
                state.detail = "died: \(why)"
                attention.append((session, "died: \(why)", true))
            case "Stop", "SessionEnd":
                // Only announce a finish that followed real work, not an idle re-stop.
                if state.tool != nil { attention.append((session, "finished", false)) }
                state.waiting = false
                state.inTool = false
                state.tool = nil
                state.detail = nil
                state.active = false
            case "UserPromptSubmit":
                revived.insert(session)
                state.active = true
                state.inTool = false        // a new turn begins with no tool open
                state.waiting = false
                state.detail = "thinking"
            default: break
            }
            updates[session] = state
        }
        if replay { attention = []; approvals = []; questions = [] }
        guard !updates.isEmpty || !attention.isEmpty || !approvals.isEmpty
                || !questions.isEmpty || !fails.isEmpty || !revived.isEmpty
                || !planUpdates.isEmpty || !pidUpdates.isEmpty else { return }
        // Carry state forward on the drain queue. Reading the published `live` from here raced
        // the main thread's merge of the same dictionary, which is a crash, not a stale read.
        carried.merge(updates) { _, new in new }
        let cutoff = Date().addingTimeInterval(-3600)
        carried = carried.filter { $0.value.at > cutoff }
        DispatchQueue.main.async {
            self.live.merge(updates) { _, new in new }
            self.plans.merge(planUpdates) { _, new in new }
            self.pids.merge(pidUpdates) { _, new in new }
            for s in revived { self.failures.removeValue(forKey: s) }
            if !fails.isEmpty { self.failures.merge(fails) { _, new in new } }
            for q in questions { self.onQuestion?(q) }
            for a in approvals { self.onApproval?(a) }
            for (s, m, needs) in attention { self.onAttention?(s, m, needs) }
        }
    }

    /// Map every vendor's spelling onto one vocabulary.
    ///
    /// Claude Code sends PascalCase (`PreToolUse`), Cursor sends camelCase with its own names
    /// (`preToolUse`, `beforeSubmitPrompt`, `afterShellExecution`). The switch below only ever
    /// saw Claude's, so Cursor events landed in the spool and were silently discarded — the
    /// rows looked static while the data was arriving all along.
    /// What a tool event says the agent is doing, across vendors that describe it differently.
    ///
    /// Cursor's shell hooks name no tool and put the command at the top level. Returning nil for
    /// an event we cannot read leaves the last known activity in place, which reads better than
    /// blanking the row mid-run.
    static func activity(from obj: [String: Any]) -> (tool: String?, detail: String?)? {
        // An agent asking a question is blocked on a person, so the question itself is the
        // status. When the island is not up to raise a card the hook defers to the terminal,
        // and without this the bar could only manage a generic "needs your permission".
        if obj["tool_name"] as? String == "AskUserQuestion",
           let input = obj["tool_input"] as? [String: Any],
           let qs = input["questions"] as? [[String: Any]],
           let q = qs.first?["question"] as? String, !q.isEmpty {
            return ("AskUserQuestion", q.count > 60 ? String(q.prefix(60)) + "…" : q)
        }
        if let name = obj["tool_name"] as? String {
            return (name, describe(tool: name, input: obj["tool_input"]))
        }
        if let command = obj["command"] as? String, !command.isEmpty {
            return ("Shell", describe(tool: "Shell", input: ["command": command]))
        }
        return nil
    }

    /// The whole ask, not the one-line summary the row shows.
    static func fullText(tool: String, input: Any?) -> String? {
        guard let d = input as? [String: Any] else { return nil }
        if let c = (d["command"] as? String) ?? (d["cmd"] as? String) { return c }
        if let p = d["file_path"] as? String {
            var out = p
            if let new = (d["new_string"] as? String) ?? (d["content"] as? String) {
                out += "\n\n" + new
            }
            return out
        }
        guard let data = try? JSONSerialization.data(withJSONObject: d,
                                                     options: [.prettyPrinted, .sortedKeys])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func canonical(_ raw: String) -> String {
        switch raw {
        // Claude Code — already canonical
        case "PreToolUse", "PostToolUse", "Notification", "PermissionRequest",
             "Stop", "SessionEnd", "SessionStart", "UserPromptSubmit", "StopFailure":
            return raw
        // Cursor
        case "preToolUse", "beforeShellExecution", "beforeMCPExecution", "beforeReadFile":
            return "PreToolUse"
        case "postToolUse", "afterShellExecution", "afterMCPExecution", "afterFileEdit":
            return "PostToolUse"
        case "afterAgentResponse", "stop":            return "Stop"
        case "sessionStart", "subagentStart":         return "SessionStart"
        case "sessionEnd", "subagentStop":            return "SessionEnd"
        case "beforeSubmitPrompt":                    return "UserPromptSubmit"
        case "afterAgentThought":                     return "PostToolUse"
        default:
            // Unknown spellings normalise to PascalCase rather than being dropped, so a vendor
            // adding an event degrades to "something happened" instead of silence.
            guard let f = raw.first else { return raw }
            return f.uppercased() + raw.dropFirst()
        }
    }

    /// One short human line for what the tool is doing — the thing worth reading at a glance.
    private static func describe(tool: String?, input: Any?) -> String? {
        guard let tool else { return nil }
        let d = input as? [String: Any] ?? [:]
        // The model writes an active-voice summary for most calls ("Debug why hook writes
        // nothing live"); the raw command is what three identical `python3 - <<'PY'` lines
        // look like in a notch. Prefer the sentence, keep the command for the expanded card.
        if let described = (d["description"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !described.isEmpty {
            return described.count > 52 ? String(described.prefix(52)) + "…" : described
        }
        func short(_ s: String?, _ n: Int = 44) -> String? {
            guard let s, !s.isEmpty else { return nil }
            let one = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? s
            return one.count > n ? String(one.prefix(n)) + "…" : one
        }
        switch tool {
        case "Bash", "Shell", "run_terminal_cmd":
            return short((d["command"] as? String) ?? (d["cmd"] as? String))
        case "Read", "Edit", "Write":
            let p = (d["file_path"] as? String) ?? ""
            return "\(tool) \((p as NSString).lastPathComponent)"
        case "Grep":  return "Grep \(short(d["pattern"] as? String, 28) ?? "")"
        case "Task":  return short(d["description"] as? String)
        default:      return tool
        }
    }
}
