import Foundation

/// Per-session facts the statusLine reports — context pressure above all.
///
/// Auto-compaction fires mid-task and makes an agent lose the thread (claude-code#10948), so
/// knowing session 7 of 10 is at 93% is the difference between landing it and losing it.
struct SessionStatus {
    var contextPct: Int?
    var model: String?
    var costUSD: Double?
    var linesAdded: Int?
    var linesRemoved: Int?
    /// Everything this session has spent, input + output — what "how big is this chat" means.
    var totalTokens: Int?
}

enum SessionStatuses {
    private static let dir = "/tmp/agentisland-status"
    private static var cache: [String: SessionStatus] = [:]
    private static var readAt = Date.distantPast

    static func all() -> [String: SessionStatus] {
        guard Date().timeIntervalSince(readAt) > 4 else { return cache }
        readAt = Date()
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return cache }
        var out: [String: SessionStatus] = [:]
        for f in files where f.hasSuffix(".json") {
            guard let data = FileManager.default.contents(atPath: "\(dir)/\(f)"),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            var s = SessionStatus()
            if let cw = o["context_window"] as? [String: Any] {
                s.contextPct = (cw["used_percentage"] as? NSNumber)?.intValue
                let i = (cw["total_input_tokens"] as? NSNumber)?.intValue ?? 0
                let o = (cw["total_output_tokens"] as? NSNumber)?.intValue ?? 0
                if i + o > 0 { s.totalTokens = i + o }
            }
            s.model = (o["model"] as? [String: Any])?["display_name"] as? String
            if let c = o["cost"] as? [String: Any] {
                s.costUSD = (c["total_cost_usd"] as? NSNumber)?.doubleValue
                s.linesAdded = (c["total_lines_added"] as? NSNumber)?.intValue
                s.linesRemoved = (c["total_lines_removed"] as? NSNumber)?.intValue
            }
            out[String(f.dropLast(5))] = s
        }
        if !out.isEmpty { cache = out }
        return cache
    }

    static func get(_ sessionId: String) -> SessionStatus? { all()[sessionId] }
}
