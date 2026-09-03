import Foundation

/// Warp identifiers read from a process's environment, cached for the life of that process.
///
/// Read via one KERN_PROCARGS2 sysctl per unseen pid and cached for the process's life — the
/// environment block is fixed at exec time, so asking twice is pure waste.
enum ProcEnv {
    /// The environment facts that identify where an agent is running and how to reach it.
    struct Info {
        var focusURL: String?          // Warp
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

    private static var cache: [Int: Info] = [:]
    private static let lock = NSLock()

    /// Fetch every unknown pid in a single `ps` call.
    static func prime(pids: [Int]) {
        lock.lock()
        let missing = pids.filter { cache[$0] == nil }
        lock.unlock()
        guard !missing.isEmpty else { return }

        var found: [Int: Info] = [:]
        for pid in missing {
            guard let ae = Proc.argsEnv(pid: pid) else { continue }
            var i = Info()
            var wantsResume = false
            for a in ae.argv {
                if wantsResume { i.resumeSession = a; wantsResume = false }
                if a == "--resume" || a == "-r" { wantsResume = true }
            }
            i.focusURL = ae.env["WARP_FOCUS_URL"]
            i.itermSession = ae.env["ITERM_SESSION_ID"]
            i.appleSession = ae.env["TERM_SESSION_ID"]
            i.kittyWindow = ae.env["KITTY_WINDOW_ID"]
            i.weztermPane = ae.env["WEZTERM_PANE"]
            i.termProgram = ae.env["TERM_PROGRAM"]
            i.bundleID = ae.env["__CFBundleIdentifier"]
            i.jetbrains = ae.env["TERMINAL_EMULATOR"]?.contains("JetBrains") ?? false
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
