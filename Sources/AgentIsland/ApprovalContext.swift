import Foundation

/// Everything worth knowing before answering an approval, assembled from what is already on disk.
struct ApprovalContext {
    let why: String?          // the agent's own words immediately before the ask
    let trail: [String]       // recent tool calls, newest last
    let risks: [String]       // patterns that make this ask worth a second look

    /// A bounded tail read of the session's transcript plus in-memory hook state — no spawns,
    /// so assembling context can never make the card slower than the decision.
    static func gather(for approval: Approval, trail: [String]) -> ApprovalContext {
        ApprovalContext(why: lastAssistantText(session: approval.session, cwd: approval.cwd),
                        trail: trail,
                        risks: riskFlags(in: approval.fullInput ?? approval.detail))
    }

    /// The last thing the agent said before asking — the single most decision-changing line.
    static func lastAssistantText(session: String, cwd: String?) -> String? {
        guard let path = Transcript.path(sessionId: session, cwd: cwd) else { return nil }
        let tail = Tail.read(path: path, bytes: 256 * 1024)
        var last: String?
        for line in tail.split(whereSeparator: \.isNewline) {
            guard line.contains("\"assistant\""), line.contains("\"text\""),
                  let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let msg = obj["message"] as? [String: Any],
                  msg["role"] as? String == "assistant",
                  let content = msg["content"] as? [[String: Any]]
            else { continue }
            for block in content where block["type"] as? String == "text" {
                if let t = block["text"] as? String,
                   !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { last = t }
            }
        }
        return last?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Purely lexical — a highlight, never a verdict. False positives are cheap; a missed
    /// destructive command is not, so the patterns err broad.
    static func riskFlags(in text: String) -> [String] {
        let t = text.lowercased()
        var out: [String] = []
        let patterns: [(String, String)] = [
            ("rm -rf", "recursive delete"), ("rm -r ", "recursive delete"),
            ("sudo ", "runs as root"), ("--force", "forced"), ("-f ", "forced"),
            ("git push", "publishes commits"), ("git reset --hard", "discards changes"),
            ("drop table", "drops a table"), ("drop database", "drops a database"),
            ("truncate ", "truncates data"), ("delete from", "deletes rows"),
            ("kubectl delete", "deletes k8s resources"), ("terraform destroy", "destroys infra"),
            ("> /dev/", "writes to a device"), ("chmod 777", "world-writable"),
            ("curl ", "network fetch"), ("wget ", "network fetch"),
            (":(){ :|:& };:", "fork bomb"), ("mkfs", "formats a disk"),
        ]
        for (needle, label) in patterns where t.contains(needle) {
            if !out.contains(label) { out.append(label) }
        }
        return out
    }
}

/// Keeps the hook waiting while the user reads: a fresh `<id>.hold` beside the decision file
/// extends the hook's own loop past its base timeout, up to the hook's hard ceiling.
@MainActor
final class ApprovalHold {
    private var timer: Timer?
    private var path: String?

    func begin(id: String) {
        end()
        let p = (Approvals.decisionsDir as NSString).appendingPathComponent(id + ".hold")
        path = p
        FileManager.default.createFile(atPath: p, contents: nil,
                                       attributes: [.posixPermissions: 0o600])
        // The hook treats a hold older than 10s as abandoned, so refresh well inside that.
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { _ in
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: p)
        }
    }

    func end() {
        timer?.invalidate(); timer = nil
        if let path { try? FileManager.default.removeItem(atPath: path) }
        path = nil
    }
}
