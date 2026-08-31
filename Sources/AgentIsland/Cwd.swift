import Foundation

/// Working directory of a process, cached for its lifetime.
///
/// `lsof` costs roughly 40 ms a call and a process cannot change the directory it was launched
/// in, so asking twice is pure waste. Twelve uncached calls per refresh were most of the gap
/// between the 0.9 s the parts measured and the 2.5 s discovery actually took.
enum Cwd {
    private static var cache: [Int: String] = [:]
    private static let lock = NSLock()

    /// One `lsof` invocation for every unknown pid, rather than one per pid.
    static func map(pids: [Int]) -> [String: Int] {
        lock.lock()
        let unknown = pids.filter { cache[$0] == nil }
        lock.unlock()

        if !unknown.isEmpty {
            let list = unknown.map(String.init).joined(separator: ",")
            let out = Shell.runSync("/bin/sh", ["-c",
                "lsof -a -p \(list) -d cwd -Fpn 2>/dev/null"])
            var current: Int?
            var found: [Int: String] = [:]
            for line in out.split(whereSeparator: \.isNewline) {
                if line.hasPrefix("p") { current = Int(line.dropFirst()) }
                else if line.hasPrefix("n"), let pid = current {
                    found[pid] = String(line.dropFirst())
                }
            }
            // Record a miss too, so a pid we cannot read is not retried every cycle.
            for pid in unknown where found[pid] == nil { found[pid] = "" }
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
