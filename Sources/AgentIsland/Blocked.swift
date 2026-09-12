import Foundation

/// What a blocked background agent is actually waiting to be told.
///
/// `claude agents --json` reports `blocked` but not the question; that lives in the job's own
/// state file. Without it a blocked agent is unactionable, which is how two of them sat for
/// months.
enum Blocked {
    // Reached from `nonisolated` sort comparators, so the statics need the same guard Transcript uses.
    private static let lock = NSLock()
    private static var cache: [String: String] = [:]
    private static var interactive: Set<String> = []
    private static var checkedAt = Date.distantPast

    /// What the session is waiting to be told. Every blocked session has this, interactive or
    /// not — suppressing the text of a question you are being asked helps nobody.
    static func question(for sessionId: String) -> String? {
        refreshIfStale()
        lock.lock(); defer { lock.unlock() }
        return cache[String(sessionId.prefix(8))]
    }

    /// A session a human is conversing with. It is blocked only in the sense that it is your
    /// turn, so it keeps its question but must never earn the stalled-agent badge.
    static func isInteractive(_ sessionId: String) -> Bool {
        refreshIfStale()
        lock.lock(); defer { lock.unlock() }
        return interactive.contains(String(sessionId.prefix(8)))
    }

    /// Take the snapshot up front, so a sort cannot see it change between two comparisons.
    static func refresh() { refreshIfStale() }

    private static func refreshIfStale() {
        // Stamp before scanning, not after: a concurrent caller then skips rather than
        // duplicating the walk, and the file I/O never happens under the lock.
        lock.lock()
        guard Date().timeIntervalSince(checkedAt) > 20 else { lock.unlock(); return }
        checkedAt = Date()
        lock.unlock()
        let dir = Home.path + "/.claude/jobs"
        guard let jobs = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        var found: [String: String] = [:]
        var chatting: Set<String> = []
        for job in jobs {
            let p = "\(dir)/\(job)/state.json"
            guard let data = FileManager.default.contents(atPath: p),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (obj["state"] as? String) == "blocked",
                  (obj["tempo"] as? String) != "active" else { continue }
            let key = String(job.prefix(8))
            // `state` flips the moment any turn ends, and `tempo` follows it 20s later, so
            // neither separates a stalled agent from a chat awaiting your reply.
            // `interactiveLineage` does: it marks the sessions a human is conversing with.
            if (obj["interactiveLineage"] as? Bool) == true { chatting.insert(key) }
            if let needs = (obj["needs"] as? String) ?? (obj["detail"] as? String), !needs.isEmpty {
                found[key] = needs
            }
        }
        lock.lock()
        cache = found
        interactive = chatting
        lock.unlock()
    }
}
