import Combine
import Foundation

/// A permission request waiting on the user. The hook is blocked until this is answered.
struct Approval: Identifiable, Equatable {
    let id: String            // ap_request_id the hook is polling for
    let session: String
    let tool: String
    let detail: String
    let deadline: Date        // hook gives up at this point; drop the card with it
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
}

/// Tails the hook spool. Hooks append one JSON line per event; the file is the whole IPC.
final class HookStream: ObservableObject {
    static let spool = "/tmp/agentisland-events.jsonl"

    @Published private(set) var live: [String: LiveState] = [:]
    /// Sessions that DIED rather than finished — a rate-limited run currently looks identical
    /// to a completed one, which is how a stalled fleet goes unnoticed.
    @Published private(set) var failures: [String: String] = [:]
    /// (sessionId, message, needsInput) — fires once per attention-worthy transition.
    var onAttention: ((String, String, Bool) -> Void)?
    /// A tool is blocked waiting for the user to allow or deny it.
    var onApproval: ((Approval) -> Void)?
    /// An agent asked a multiple-choice question and is blocked on the answer.
    var onQuestion: ((Question) -> Void)?
    private var source: DispatchSourceFileSystemObject?
    private var handle: FileHandle?
    private var offset: UInt64 = 0

    func start() {
        if !FileManager.default.fileExists(atPath: Self.spool) {
            FileManager.default.createFile(atPath: Self.spool, contents: nil)
        }
        guard let h = FileHandle(forReadingAtPath: Self.spool) else { return }
        handle = h
        offset = (try? h.seekToEnd()) ?? 0

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: h.fileDescriptor, eventMask: [.extend, .write],
            queue: DispatchQueue.global(qos: .utility))
        src.setEventHandler { [weak self] in self?.drain() }
        src.resume()
        source = src
    }

    private func drain() {
        guard let h = handle else { return }
        h.seek(toFileOffset: offset)
        let data = h.readDataToEndOfFile()
        offset = h.offsetInFile
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }

        var updates: [String: LiveState] = [:]
        var attention: [(String, String, Bool)] = []
        var approvals: [Approval] = []
        var questions: [Question] = []
        var fails: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  var obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
            else { continue }

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

            // The permission hook wraps its payload so it can carry the id it is polling on.
            if let reqID = obj["ap_request_id"] as? String,
               let payload = obj["payload"] as? [String: Any] {
                let tool = payload["tool_name"] as? String ?? "tool"
                let approval = Approval(
                    id: reqID,
                    session: payload["session_id"] as? String ?? "",
                    tool: tool,
                    detail: Self.describe(tool: tool, input: payload["tool_input"]) ?? tool,
                    deadline: Date().addingTimeInterval(19))
                approvals.append(approval)
                obj = payload
            }
            guard let session = obj["session_id"] as? String else { continue }
            let event = obj["hook_event_name"] as? String ?? ""
            var state = updates[session] ?? live[session] ?? LiveState()
            state.at = Date()

            switch event {
            case "PreToolUse", "PostToolUse":
                state.tool = obj["tool_name"] as? String
                state.detail = Self.describe(tool: state.tool, input: obj["tool_input"])
                state.waiting = false
            case "Notification", "PermissionRequest":
                state.waiting = true
                let msg = obj["message"] as? String ?? "needs your input"
                state.detail = msg
                attention.append((session, msg, true))
            case "StopFailure":
                let why = (obj["error_type"] as? String) ?? "failed"
                fails[session] = why
                state.waiting = false
                state.detail = "died: \(why)"
                attention.append((session, "died: \(why)", true))
            case "Stop", "SessionEnd":
                // Only announce a finish that followed real work, not an idle re-stop.
                if state.tool != nil { attention.append((session, "finished", false)) }
                state.waiting = false
                state.tool = nil
                state.detail = nil
            case "UserPromptSubmit":
                state.waiting = false
                state.detail = "thinking"
            default: break
            }
            updates[session] = state
        }
        guard !updates.isEmpty || !attention.isEmpty || !approvals.isEmpty
                || !questions.isEmpty || !fails.isEmpty else { return }
        DispatchQueue.main.async {
            self.live.merge(updates) { _, new in new }
            if !fails.isEmpty { self.failures.merge(fails) { _, new in new } }
            for q in questions { self.onQuestion?(q) }
            for a in approvals { self.onApproval?(a) }
            for (s, m, needs) in attention { self.onAttention?(s, m, needs) }
        }
    }

    /// One short human line for what the tool is doing — the thing worth reading at a glance.
    private static func describe(tool: String?, input: Any?) -> String? {
        guard let tool else { return nil }
        let d = input as? [String: Any] ?? [:]
        func short(_ s: String?, _ n: Int = 44) -> String? {
            guard let s, !s.isEmpty else { return nil }
            let one = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? s
            return one.count > n ? String(one.prefix(n)) + "…" : one
        }
        switch tool {
        case "Bash":  return short(d["command"] as? String)
        case "Read", "Edit", "Write":
            let p = (d["file_path"] as? String) ?? ""
            return "\(tool) \((p as NSString).lastPathComponent)"
        case "Grep":  return "Grep \(short(d["pattern"] as? String, 28) ?? "")"
        case "Task":  return short(d["description"] as? String)
        default:      return tool
        }
    }
}
