import Foundation

/// Answers the blocked hook by dropping a file where it is polling, and proves the app is
/// alive so the hook knows anyone is home to ask.
enum Approvals {
    static let decisionsDir = "/tmp/agentisland-decisions"
    static let aliveFile = "/tmp/agentisland.alive"

    /// Answer a question by writing the chosen label where the hook is polling.
    static func answer(_ question: Question, choice: String) {
        try? FileManager.default.createDirectory(atPath: decisionsDir,
                                                 withIntermediateDirectories: true)
        let path = (decisionsDir as NSString).appendingPathComponent(question.id)
        try? choice.write(toFile: path, atomically: true, encoding: .utf8)
    }

    static func decide(_ approval: Approval, allow: Bool) {
        try? FileManager.default.createDirectory(atPath: decisionsDir,
                                                 withIntermediateDirectories: true)
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
