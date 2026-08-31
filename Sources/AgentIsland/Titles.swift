import Foundation

/// Claude writes an `ai-title` line into the transcript once it can describe the session, and
/// sets the terminal title from it — which is what Warp shows on the tab. Reading it back is the
/// only way to label a row with something a human recognises; `mono-17` is a hash, not a name.
enum Titles {
    private static var cache: [String: String] = [:]
    private static var checked: [String: Date] = [:]

    static func title(for sessionId: String, cwd: String?) -> String? {
        if let hit = cache[sessionId],
           let at = checked[sessionId], Date().timeIntervalSince(at) < 30 { return hit }
        guard let path = transcriptPath(sessionId: sessionId, cwd: cwd) else { return cache[sessionId] }

        // Transcripts reach tens of MB, so let grep find the line instead of parsing the file.
        let line = Shell.runSync("/bin/sh", ["-c",
            "grep '\"ai-title\"' \(shellQuote(path)) 2>/dev/null | tail -1"])
        checked[sessionId] = Date()
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t = obj["aiTitle"] as? String, !t.isEmpty else { return cache[sessionId] }
        cache[sessionId] = t
        return t
    }

    private static var promptCache: [String: String] = [:]
    private static var promptChecked: [String: Date] = [:]

    /// Drop entries for sessions that are no longer listed, so the caches track the panel
    /// rather than every session the app has ever seen.
    static func retain(_ ids: Set<String>) {
        cache = cache.filter { ids.contains($0.key) }
        checked = checked.filter { ids.contains($0.key) }
        promptCache = promptCache.filter { ids.contains($0.key) }
        promptChecked = promptChecked.filter { ids.contains($0.key) }
    }

    /// The user's most recent instruction — the single most useful line for recognising a session.
    static func lastPrompt(for sessionId: String, cwd: String?) -> String? {
        if let hit = promptCache[sessionId],
           let at = promptChecked[sessionId], Date().timeIntervalSince(at) < 10 { return hit }
        guard let path = transcriptPath(sessionId: sessionId, cwd: cwd) else { return promptCache[sessionId] }
        let line = Shell.runSync("/bin/sh", ["-c",
            "grep '\"last-prompt\"' \(shellQuote(path)) 2>/dev/null | tail -1"])
        promptChecked[sessionId] = Date()
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t = obj["lastPrompt"] as? String, !t.isEmpty else { return promptCache[sessionId] }
        let clean = t.split(whereSeparator: \.isNewline).first.map(String.init) ?? t
        promptCache[sessionId] = clean
        return clean
    }

    private static func transcriptPath(sessionId: String, cwd: String?) -> String? {
        let fm = FileManager.default
        if let cwd {
            let slug = cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" }
                          .reduce(into: "") { $0.append($1) }
            let p = NSHomeDirectory() + "/.claude/projects/\(slug)/\(sessionId).jsonl"
            if fm.fileExists(atPath: p) { return p }
        }
        let found = Shell.runSync("/bin/sh", ["-c",
            "ls \(NSHomeDirectory())/.claude/projects/*/\(sessionId).jsonl 2>/dev/null | head -1"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return found.isEmpty ? nil : found
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
