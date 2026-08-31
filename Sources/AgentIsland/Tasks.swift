import Foundation

/// A session's todo list, which Claude keeps as one JSON file per task.
///
/// "Which agent needs me" was answerable; "how far along is it" was not. With ten sessions you
/// cannot tell one task from done apart from eight.
struct TaskProgress {
    var done: Int
    var total: Int
    var current: String?
    var blocked: Bool

    var label: String { "\(done)/\(total)" }
}

enum Tasks {
    private static var cache: [String: TaskProgress] = [:]
    private static var readAt = Date.distantPast

    static func progress(for sessionId: String) -> TaskProgress? {
        refresh()
        return cache[sessionId]
    }

    private static func refresh() {
        guard Date().timeIntervalSince(readAt) > 5 else { return }
        readAt = Date()
        let root = NSHomeDirectory() + "/.claude/tasks"
        guard let sessions = try? FileManager.default.contentsOfDirectory(atPath: root) else { return }
        var out: [String: TaskProgress] = [:]
        for sid in sessions {
            let dir = "\(root)/\(sid)"
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            var done = 0, total = 0, blocked = false
            var current: String?
            for f in files where f.hasSuffix(".json") {
                guard let d = FileManager.default.contents(atPath: "\(dir)/\(f)"),
                      let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
                total += 1
                let status = o["status"] as? String ?? ""
                if status == "completed" { done += 1 }
                if status == "in_progress" || status == "active" {
                    current = (o["activeForm"] as? String) ?? (o["subject"] as? String)
                }
                if let b = o["blockedBy"] as? [Any], !b.isEmpty { blocked = true }
            }
            if total > 0 { out[sid] = TaskProgress(done: done, total: total, current: current, blocked: blocked) }
        }
        cache = out
    }
}
