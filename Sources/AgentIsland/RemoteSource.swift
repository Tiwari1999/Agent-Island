import Foundation

/// Sessions on machines you ssh into (one host per line in ~/.config/agentisland/remotes),
/// probed by a script sent on stdin so nothing is ever installed remotely.
struct RemoteSource: AgentSource {
    let vendor: Vendor = .claude   // rows carry their real vendor; this satisfies the protocol

    static var configPath: String { Home.path + "/.config/agentisland/remotes" }

    var isAvailable: Bool { !Self.hosts().isEmpty }

    static func hosts() -> [String] {
        guard let text = try? String(contentsOfFile: configPath, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// discover() must stay fast, and ssh round-trips are anything but — an IAP tunnel takes
    /// seconds. So discover() serves the last poll and the polling runs on its own slow clock.
    private static var cache: [String: [Agent]] = [:]
    private static var polling = false
    private static var polledAt = Date.distantPast
    private static let lock = NSLock()

    func discover() -> [Agent] {
        Self.pollIfDue()
        Self.lock.lock(); defer { Self.lock.unlock() }
        return Self.cache.values.flatMap { $0 }
    }

    static func pollIfDue(interval: TimeInterval = 60) {
        lock.lock()
        let due = Date().timeIntervalSince(polledAt) > interval && !polling
        if due { polling = true; polledAt = Date() }
        lock.unlock()
        guard due else { return }
        DispatchQueue.global(qos: .utility).async {
            var fresh: [String: [Agent]] = [:]
            for host in hosts() { fresh[host] = probe(host: host) }
            lock.lock()
            cache = fresh
            polling = false
            lock.unlock()
        }
    }

    /// One ssh, script on stdin, JSON on stdout. BatchMode so a dead key can never hang a prompt.
    static func probe(host: String) -> [Agent] {
        guard let script = probeScript() else { return [] }
        let ssh = ProcessInfo.processInfo.environment["AGENTISLAND_SSH"] ?? "/usr/bin/ssh"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: ssh)
        task.arguments = ssh.hasSuffix("ssh")
            ? ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8", host, "python3", "-"]
            : [host]   // a test stub takes just the host
        let inPipe = Pipe(), outPipe = Pipe()
        task.standardInput = inPipe
        task.standardOutput = outPipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return [] }
        inPipe.fileHandleForWriting.write(script.data(using: .utf8)!)
        try? inPipe.fileHandleForWriting.close()

        let box = ProbeOut()
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            box.data = outPipe.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        var abandoned = false
        if done.wait(timeout: .now() + 20) == .timedOut {
            task.terminate()
            abandoned = done.wait(timeout: .now() + 2) == .timedOut
            Diagnostics.log("remote \(host): probe timed out")
            if abandoned { return [] }
        }
        if !abandoned { try? outPipe.fileHandleForReading.close() }
        task.waitUntilExit()
        return parse(box.data, host: host)
    }

    private final class ProbeOut: @unchecked Sendable { var data = Data() }

    static func parse(_ data: Data, host: String) -> [Agent] {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        let iso = ISO8601DateFormatter()
        return rows.compactMap { r in
            guard let sid = r["sessionId"] as? String,
                  let vendorRaw = r["vendor"] as? String,
                  let vendor = Vendor(rawValue: vendorRaw) else { return nil }
            let when = (r["lastActive"] as? String).flatMap { iso.date(from: $0) }
            return Agent(
                sessionId: "\(host):\(sid)",   // ids must not collide with a local session's
                name: nil,
                cwd: r["cwd"] as? String,
                state: r["state"] as? String,
                status: nil,
                pid: nil,                      // a remote pid means nothing to local jump/lsof
                vendor: vendor,
                lastActiveOverride: when,
                titleOverride: (r["title"] as? String) ?? (r["prompt"] as? String),
                promptOverride: r["prompt"] as? String,
                remoteHost: host)
        }
    }

    static func probeScript() -> String? {
        for dir in [Bundle.main.resourcePath, Bundle.main.bundlePath as String?] {
            if let dir, let s = try? String(contentsOfFile: dir + "/remote-probe.py",
                                            encoding: .utf8) { return s }
        }
        // Development fallback: the repo copy, resolved from an absolutised binary path —
        // argv[0] is relative when run as .build/release/AgentIsland.
        let argv0 = CommandLine.arguments[0]
        let bin = (argv0 as NSString).isAbsolutePath ? argv0
            : FileManager.default.currentDirectoryPath + "/" + argv0
        let repo = (((bin as NSString)
            .deletingLastPathComponent as NSString)
            .deletingLastPathComponent as NSString).deletingLastPathComponent
        return try? String(contentsOfFile: repo + "/hooks/remote-probe.py", encoding: .utf8)
    }
}
