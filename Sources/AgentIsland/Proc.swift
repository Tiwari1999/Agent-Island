import Darwin
import Foundation

@_silgen_name("proc_pidinfo")
private func proc_pidinfo(_ pid: Int32, _ flavor: Int32, _ arg: UInt64,
                          _ buffer: UnsafeMutableRawPointer?, _ size: Int32) -> Int32

/// The process table via syscalls: pgrep, lsof and ps cost a fork+exec each, every refresh,
/// forever — sysctl and libproc answer the same questions in microseconds with zero spawns.
enum Proc {
    /// Does this pid still exist? signal 0 tests existence without delivering anything.
    /// EPERM means it exists and belongs to someone else — only ESRCH means gone.
    static func alive(_ pid: Int) -> Bool {
        kill(Int32(pid), 0) == 0 || errno == EPERM
    }

    /// pid → parent pid, for walking up from a hook's shell to the agent that ran it.
    static func parents() -> [Int32: Int32] {
        var out: [Int32: Int32] = [:]
        walk { kp in out[kp.kp_proc.p_pid] = kp.kp_eproc.e_ppid }
        return out
    }

    /// The names an agent CLI is invoked as. Kept in one place because binding a hook to its
    /// agent process needs the same set everywhere.
    static let agentNames: Set<String> = ["claude", "codex", "cursor-agent", "agent"]

    /// Was the process at `pid` invoked as one of `names`? p_comm is the basename of the
    /// *resolved* executable, so a versioned-symlink install (~/.local/share/claude/versions/
    /// 2.1.267, where the version string IS the file) reports "2.1.267", never "claude" — and
    /// every name match missed, so no session ever bound a pid and every jump silently no-op'd.
    /// argv[0] still carries the invoked name, so fall back to its basename on a p_comm miss.
    /// The fallback runs only on a miss (never for a normal install) and spawns nothing.
    static func matches(pid: Int, comm: String?, names: Set<String>) -> Bool {
        if let c = comm, names.contains(c) { return true }
        guard let n = invokedName(Int32(pid)) else { return false }
        return names.contains(n)
    }

    /// pid → the name it was invoked as, "" for a process whose argv cannot be read.
    ///
    /// argv[0] is fixed at exec, so a pid is read once and held for its life. That is what
    /// makes a whole-table sweep affordable: cold it costs ~25ms across ~800 processes, warm
    /// only the pids that have appeared since. Still no spawns — one sysctl per new pid.
    private static var invoked: [Int32: String] = [:]
    private static let invokedLock = NSLock()

    /// The name `pid` was invoked as, or nil when its argv cannot be read.
    static func invokedName(_ pid: Int32) -> String? {
        invokedLock.lock()
        if let hit = invoked[pid] { invokedLock.unlock(); return hit.isEmpty ? nil : hit }
        invokedLock.unlock()
        // Cached even when unreadable, so a kernel task is not re-asked every refresh.
        var name = ""
        if let argv0 = argsEnv(pid: Int(pid))?.argv.first {
            name = (argv0 as NSString).lastPathComponent
        }
        invokedLock.lock(); invoked[pid] = name; invokedLock.unlock()
        return name.isEmpty ? nil : name
    }

    /// The nearest ancestor whose name matches, walking up from `pid`.
    static func ancestor(of pid: Int, named names: Set<String>, maxHops: Int = 8) -> Int? {
        let comm = all(), parent = parents()
        var cur = Int32(pid)
        for _ in 0..<maxHops {
            if matches(pid: Int(cur), comm: comm[cur], names: names) { return Int(cur) }
            guard let p = parent[cur], p > 1 else { return nil }
            cur = p
        }
        return nil
    }

    /// pid → comm (the 16-char process name) for every process this user can see.
    static func all() -> [Int32: String] {
        var out: [Int32: String] = [:]
        walk { kp in
            var comm = kp.kp_proc.p_comm
            out[kp.kp_proc.p_pid] = withUnsafeBytes(of: &comm) { b in
                String(decoding: b.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
        }
        return out
    }

    private static func walk(_ each: (kinfo_proc) -> Void) {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return }
        // The table can grow between the size call and the fetch; leave headroom.
        size += size / 8
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 4, &buf, &size, nil, 0) == 0 else { return }
        let stride = MemoryLayout<kinfo_proc>.stride
        buf.withUnsafeBytes { raw in
            for off in Swift.stride(from: 0, to: size - stride + 1, by: stride) {
                let kp = raw.load(fromByteOffset: off, as: kinfo_proc.self)
                guard kp.kp_proc.p_pid > 0 else { continue }
                each(kp)
            }
        }
    }

    /// Pids of every process known by one of `names` — pgrep -x, without the fork, and
    /// without trusting p_comm to carry the tool's name.
    ///
    /// The same versioned-symlink layout that broke `matches` breaks an exact comm scan, and
    /// this is the one discovery uses: with fourteen claude sessions live it returned none, so
    /// no session bound a pid from its own argv and only the hook fallback bound anything.
    static func pids(named names: Set<String>) -> [Int] {
        let comm = all()
        invokedLock.lock()
        invoked = invoked.filter { comm[$0.key] != nil }   // bounded to what is still alive
        invokedLock.unlock()
        return comm.compactMap { pid, c in
            if names.contains(c) { return Int(pid) }
            guard let n = invokedName(pid), names.contains(n) else { return nil }
            return Int(pid)
        }.sorted()
    }

    /// argv and environment of one process — `ps eww` for a single pid, without the fork.
    /// Only works for processes of the same user, which is every process this app monitors.
    static func argsEnv(pid: Int) -> (argv: [String], env: [String: String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, Int32(pid)]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return nil }

        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        // Layout: argc, exec_path, padding NULs, argv[0..argc-1], env strings, each NUL-ended.
        var strings: [String] = []
        var i = 4
        var start = -1
        var seenExec = false
        while i < size {
            if buf[i] == 0 {
                if start >= 0 {
                    let s = String(decoding: buf[start..<i], as: UTF8.self)
                    if seenExec { strings.append(s) } else { seenExec = true }
                    start = -1
                }
            } else if start < 0 {
                start = i
            }
            i += 1
        }
        let argv = Array(strings.prefix(Int(argc)))
        var env: [String: String] = [:]
        for s in strings.dropFirst(Int(argc)) {
            guard let eq = s.firstIndex(of: "=") else { continue }
            env[String(s[..<eq])] = String(s[s.index(after: eq)...])
        }
        return (argv, env)
    }

    /// Working directory of one process — what lsof -d cwd answers, without the fork.
    /// The process's controlling terminal as "/dev/ttysNNN", or nil if it has none. Terminal.app
    /// exposes only the tty in its scripting dictionary — its TERM_SESSION_ID is a UUID that maps
    /// to nothing there — so the tty is the only handle that can focus the right tab. Syscall, no
    /// spawn, so it is safe on the refresh path.
    static func tty(pid: Int) -> String? {
        let PROC_PIDTBSDINFO: Int32 = 3
        var info = proc_bsdinfo()
        let n = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(Int32(pid), PROC_PIDTBSDINFO, 0, $0, Int32(MemoryLayout<proc_bsdinfo>.size))
        }
        guard n >= Int32(MemoryLayout<proc_bsdinfo>.size), info.e_tdev != UInt32.max,
              info.e_tdev != 0, let name = devname(dev_t(bitPattern: info.e_tdev), mode_t(S_IFCHR))
        else { return nil }
        let dev = String(cString: name)
        return dev.isEmpty ? nil : "/dev/" + dev
    }

    static func cwd(pid: Int) -> String? {
        // proc_vnodepathinfo: two vnode_info_path entries (cdir, rdir), each a 152-byte
        // vnode_info followed by a MAXPATHLEN path. The layout has been ABI-stable since 10.5.
        let vnodeInfoSize = 152
        let pathLen = 1024
        let entry = vnodeInfoSize + pathLen
        var buf = [UInt8](repeating: 0, count: entry * 2)
        let PROC_PIDVNODEPATHINFO: Int32 = 9
        let n = buf.withUnsafeMutableBytes {
            proc_pidinfo(Int32(pid), PROC_PIDVNODEPATHINFO, 0, $0.baseAddress, Int32(entry * 2))
        }
        guard n > Int32(vnodeInfoSize) else { return nil }
        let path = String(decoding: buf[vnodeInfoSize...].prefix(while: { $0 != 0 }), as: UTF8.self)
        return path.isEmpty ? nil : path
    }
}
