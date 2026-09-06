import Foundation

/// Answers the blocked hook by dropping a file where it is polling, and proves the app is
/// alive so the hook knows anyone is home to ask.
enum Approvals {
    static let decisionsDir = "/tmp/agentisland-decisions"
    static let aliveFile = "/tmp/agentisland.alive"

    /// The directory lives in world-writable /tmp, and a file in it approves a shell command, so
    /// it is owner-only: otherwise any local process could answer on the user's behalf.
    private static func ensureDir() {
        try? FileManager.default.createDirectory(
            atPath: decisionsDir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                               ofItemAtPath: decisionsDir)
    }

    /// Answer a question by writing the chosen label where the hook is polling.
    /// One write for the whole ask: question text to the chosen label, or labels when the
    /// question allows several. The hook validates every entry against what it offered.
    static func answer(_ question: Question, picks: [String: [String]]) {
        ensureDir()
        var body: [String: Any] = [:]
        for item in question.items {
            guard let chosen = picks[item.text], !chosen.isEmpty else { continue }
            body[item.text] = item.multi ? chosen : chosen[0]
        }
        guard body.count == question.items.count,
              let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        let path = (decisionsDir as NSString).appendingPathComponent(question.id)
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    static func decide(_ approval: Approval, allow: Bool) {
        ensureDir()
        let path = (decisionsDir as NSString).appendingPathComponent(approval.id)
        try? (allow ? "allow" : "deny").write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// The hook treats a heartbeat older than 15s as "no island", so beat well inside that.
    static func startHeartbeat() -> Timer {
        touch()
        return Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in touch() }
    }

    private static func touch() {
        let fm = FileManager.default
        if fm.fileExists(atPath: aliveFile) {
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: aliveFile)
        } else {
            fm.createFile(atPath: aliveFile, contents: Data())
        }
    }
}
