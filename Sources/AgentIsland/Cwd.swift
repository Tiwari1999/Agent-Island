import Foundation

/// Working directory of a process, cached for its lifetime.
///
/// One PROC_PIDVNODEPATHINFO syscall per unseen pid, cached for its life — this was an `lsof`
/// spawn costing ~40 ms; the syscall costs microseconds and no process.
enum Cwd {
    private static var cache: [Int: String] = [:]
    private static let lock = NSLock()

    /// One `lsof` invocation for every unknown pid, rather than one per pid.
    static func map(pids: [Int]) -> [String: Int] {
        lock.lock()
        let unknown = pids.filter { cache[$0] == nil }
        lock.unlock()

        if !unknown.isEmpty {
            var found: [Int: String] = [:]
            for pid in unknown { found[pid] = Proc.cwd(pid: pid) ?? "" }
            lock.lock(); cache.merge(found) { _, new in new }; lock.unlock()
        }

        lock.lock(); defer { lock.unlock() }
        var byCwd: [String: Int] = [:]
        for pid in pids {
            guard let cwd = cache[pid], !cwd.isEmpty else { continue }
            // Two agents in one directory cannot be told apart, so claim neither.
            if byCwd[cwd] == nil { byCwd[cwd] = pid } else { byCwd[cwd] = -1 }
        }
        return byCwd.filter { $0.value > 0 }
    }

    static func retain(_ alive: Set<Int>) {
        lock.lock(); cache = cache.filter { alive.contains($0.key) }; lock.unlock()
    }
}
