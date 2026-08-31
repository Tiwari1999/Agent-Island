import Foundation

/// Warp identifiers read from a process's environment, cached for the life of that process.
///
/// These were being fetched with two separate `ps` calls per agent on every refresh — one for the
/// focus URL, one for the session UUID — despite both living in the same environment block, which
/// never changes once a process has started. At eight agents that was sixteen process spawns
/// every four seconds for values that are fixed at exec time.
enum ProcEnv {
    struct Warp { let focusURL: String?; let sessionUUID: String? }

    private static var cache: [Int: Warp] = [:]
    private static let lock = NSLock()

    /// Fetch every unknown pid in a single `ps` call.
    static func prime(pids: [Int]) {
        lock.lock()
        let missing = pids.filter { cache[$0] == nil }
        lock.unlock()
        guard !missing.isEmpty else { return }

        let list = missing.map(String.init).joined(separator: ",")
        let out = Shell.runSync("/bin/ps", ["eww", "-o", "pid=,command=", "-p", list])

        var found: [Int: Warp] = [:]
        for line in out.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let first = fields.first, let pid = Int(first) else { continue }
            var focus: String?, uuid: String?
            for f in fields {
                if f.hasPrefix("WARP_FOCUS_URL=") { focus = String(f.dropFirst(15)) }
                else if f.hasPrefix("WARP_TERMINAL_SESSION_UUID=") { uuid = String(f.dropFirst(27)) }
            }
            found[pid] = Warp(focusURL: focus, sessionUUID: uuid)
        }
        // A pid with no Warp vars still gets an entry, so we never re-ask about it.
        for pid in missing where found[pid] == nil {
            found[pid] = Warp(focusURL: nil, sessionUUID: nil)
        }
        lock.lock(); cache.merge(found) { _, new in new }; lock.unlock()
    }

    static func warp(pid: Int) -> Warp {
        lock.lock(); defer { lock.unlock() }
        return cache[pid] ?? Warp(focusURL: nil, sessionUUID: nil)
    }

    /// Drop pids that are gone, so the cache cannot grow without bound.
    static func retain(_ alive: Set<Int>) {
        lock.lock(); cache = cache.filter { alive.contains($0.key) }; lock.unlock()
    }
}
