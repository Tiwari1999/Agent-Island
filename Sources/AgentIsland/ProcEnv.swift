import Foundation

/// Warp identifiers read from a process's environment, cached for the life of that process.
///
/// These were being fetched with two separate `ps` calls per agent on every refresh — one for the
/// focus URL, one for the session UUID — despite both living in the same environment block, which
/// never changes once a process has started. At eight agents that was sixteen process spawns
/// every four seconds for values that are fixed at exec time.
enum ProcEnv {
    /// The environment facts that identify where an agent is running and how to reach it.
    struct Info {
        var focusURL: String?          // Warp
        var sessionUUID: String?       // Warp
        var itermSession: String?      // iTerm2
        var appleSession: String?      // Terminal.app
        var kittyWindow: String?       // kitty
        var weztermPane: String?       // WezTerm
        var termProgram: String?
        var jetbrains: Bool = false
        /// Set by macOS on every process an app launches — the most reliable host id there is.
        var bundleID: String?
        /// From argv (`claude --resume <id>`): the exact session this process is running.
        var resumeSession: String?
    }
    typealias Warp = Info

    private static var cache: [Int: Info] = [:]
    private static let lock = NSLock()

    /// Fetch every unknown pid in a single `ps` call.
    static func prime(pids: [Int]) {
        lock.lock()
        let missing = pids.filter { cache[$0] == nil }
        lock.unlock()
        guard !missing.isEmpty else { return }

        let list = missing.map(String.init).joined(separator: ",")
        let out = Shell.runSync("/bin/ps", ["eww", "-o", "pid=,command=", "-p", list])

        var found: [Int: Info] = [:]
        for line in out.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let first = fields.first, let pid = Int(first) else { continue }
            var i = Info()
            var wantsResume = false
            for f in fields {
                if wantsResume { i.resumeSession = String(f); wantsResume = false }
                if f == "--resume" || f == "-r" { wantsResume = true }
                func val(_ key: String) -> String? {
                    f.hasPrefix(key) ? String(f.dropFirst(key.count)) : nil
                }
                if let v = val("WARP_FOCUS_URL=") { i.focusURL = v }
                else if let v = val("WARP_TERMINAL_SESSION_UUID=") { i.sessionUUID = v }
                else if let v = val("ITERM_SESSION_ID=") { i.itermSession = v }
                else if let v = val("TERM_SESSION_ID=") { i.appleSession = v }
                else if let v = val("KITTY_WINDOW_ID=") { i.kittyWindow = v }
                else if let v = val("WEZTERM_PANE=") { i.weztermPane = v }
                else if let v = val("TERM_PROGRAM=") { i.termProgram = v }
                else if let v = val("__CFBundleIdentifier=") { i.bundleID = v }
                else if let v = val("TERMINAL_EMULATOR="), v.contains("JetBrains") { i.jetbrains = true }
            }
            found[pid] = i
        }
        // A pid we could not read still gets an entry, so we never re-ask about it.
        for pid in missing where found[pid] == nil { found[pid] = Info() }
        lock.lock(); cache.merge(found) { _, new in new }; lock.unlock()
    }

    static func info(pid: Int) -> Info {
        lock.lock(); defer { lock.unlock() }
        return cache[pid] ?? Info()
    }
    static func warp(pid: Int) -> Info { info(pid: pid) }

    /// Drop pids that are gone, so the cache cannot grow without bound.
    static func retain(_ alive: Set<Int>) {
        lock.lock(); cache = cache.filter { alive.contains($0.key) }; lock.unlock()
    }
}
