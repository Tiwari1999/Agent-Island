import Foundation

/// Answers the blocked hook by dropping a file where it is polling, and proves the app is
/// alive so the hook knows anyone is home to ask.
enum Approvals {
    /// Request ids come off the spool and become filenames. They are generated as
    /// "aq-<pid>-<ts>", so anything else is either a bug or someone aiming a write at a path
    /// of their choosing — reject rather than sanitise, since there is no valid odd id.
    static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64
            && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

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
    @discardableResult
    /// Mark that the reader is engaged with this card, so the hook waits its full window
    /// rather than falling through to the terminal. Written once and never refreshed: the
    /// refreshing version it replaces stalled whenever AppKit was tracking the mouse — while
    /// the card was in use — and the hook exited mid-answer.
    static func touch(_ id: String) {
        guard validID(id) else { return }
        ensureDir()
        let p = (decisionsDir as NSString).appendingPathComponent(id + ".touched")
        // Re-stamp on every interaction so the hook's grace slides forward. This is driven by
        // real input, not a repeating timer — the timer version stalled whenever AppKit was
        // tracking the mouse, which is exactly when the card was in use.
        if FileManager.default.fileExists(atPath: p) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: p)
        } else {
            FileManager.default.createFile(atPath: p, contents: nil,
                                           attributes: [.posixPermissions: 0o600])
        }
    }

    /// Tell the hook to stand down so Claude's own picker can appear. Without this the turn
    /// stays held for the rest of the ceiling and "open in terminal" lands on nothing.
    static func skip(_ id: String) {
        guard validID(id) else { return }
        ensureDir()
        FileManager.default.createFile(
            atPath: (decisionsDir as NSString).appendingPathComponent(id + ".skip"),
            contents: nil, attributes: [.posixPermissions: 0o600])
    }

    static func answer(_ question: Question, picks: [String: [String]],
                       typed: [String: String] = [:]) -> Bool {
        guard validID(question.id) else { return false }
        ensureDir()
        var body: [String: Any] = [:]
        for item in question.items {
            let chosen = picks[item.text] ?? []
            // Typed text travels marked rather than as a bare string, so the hook can keep
            // refusing anything that is neither an offered label nor a deliberate answer.
            let free = (typed[item.text] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !free.isEmpty {
                body[item.text] = item.multi ? chosen.map { $0 as Any } + [["other": free]]
                                             : ["other": free]
                continue
            }
            guard !chosen.isEmpty else { continue }
            body[item.text] = item.multi ? chosen : chosen[0]
        }
        guard body.count == question.items.count,
              let data = try? JSONSerialization.data(withJSONObject: body) else { return false }
        let path = (decisionsDir as NSString).appendingPathComponent(question.id)
        do { try data.write(to: URL(fileURLWithPath: path), options: .atomic) } catch { return false }
        return true
    }

    /// The hook deletes the file the moment it reads it, so a file still sitting there means
    /// nobody was listening. Silently writing into the void is how a set of answers the user
    /// actually gave went nowhere.
    static func wasRead(_ id: String, within: TimeInterval = 3, then: @escaping (Bool) -> Void) {
        let path = (decisionsDir as NSString).appendingPathComponent(id)
        let deadline = Date().addingTimeInterval(within)
        func poll() {
            if !FileManager.default.fileExists(atPath: path) { then(true); return }
            guard Date() < deadline else {
                try? FileManager.default.removeItem(atPath: path)   // nobody will ever read it
                then(false); return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: poll)
        }
        poll()
    }

    static func decide(_ approval: Approval, allow: Bool) {
        guard validID(approval.id) else { return }
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
