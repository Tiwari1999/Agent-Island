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

    /// The nearest ancestor whose name matches, walking up from `pid`.
    static func ancestor(of pid: Int, named names: Set<String>, maxHops: Int = 8) -> Int? {
        let comm = all(), parent = parents()
        var cur = Int32(pid)
        for _ in 0..<maxHops {
            if let c = comm[cur], names.contains(c) { return Int(cur) }
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

    /// Pids whose process name matches exactly — pgrep -x, without the fork.
    static func pids(comm name: String) -> [Int] {
        all().compactMap { $0.value == name ? Int($0.key) : nil }.sorted()
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
