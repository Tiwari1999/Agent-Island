import Foundation

/// What a blocked background agent is actually waiting to be told.
///
/// `claude agents --json` reports `blocked` but not the question; that lives in the job's own
/// state file. Without it a blocked agent is unactionable, which is how two of them sat for
/// months.
enum Blocked {
    private static var cache: [String: String] = [:]
    private static var checkedAt = Date.distantPast

    static func question(for sessionId: String) -> String? {
        refreshIfStale()
        return cache[String(sessionId.prefix(8))]
    }

    private static func refreshIfStale() {
        guard Date().timeIntervalSince(checkedAt) > 20 else { return }
        checkedAt = Date()
        let dir = Home.path + "/.claude/jobs"
        guard let jobs = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        var found: [String: String] = [:]
        for job in jobs {
            let p = "\(dir)/\(job)/state.json"
            guard let data = FileManager.default.contents(atPath: p),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (obj["state"] as? String) == "blocked" else { continue }
            if let needs = (obj["needs"] as? String) ?? (obj["detail"] as? String), !needs.isEmpty {
                found[String(job.prefix(8))] = needs
            }
        }
        cache = found
    }
}
