import Foundation

/// Claude writes an `ai-title` line into the transcript once it can describe the session, and a
/// `last-prompt` line for the most recent instruction. Reading them back is the only way to label
/// a row with something a human recognises; `mono-17` is a hash, not a name.
///
/// Both are read once per file version. Time-based caches were the app's largest energy cost: a
/// ten-second prompt cache against a twenty-second refresh missed every single time, so every
/// session spawned a `grep` on every cycle — eighteen processes a cycle here, and one per agent
/// at any scale. A transcript is append-only, so unchanged bytes cannot hold a newer answer.
enum Titles {
    private struct Entry { var mtime: Date; var title: String?; var prompt: String? }
    private static var cache: [String: Entry] = [:]

    static func retain(_ ids: Set<String>) { cache = cache.filter { ids.contains($0.key) } }

    static func title(for sessionId: String, cwd: String?) -> String? {
        entry(sessionId, cwd)?.title
    }

    static func lastPrompt(for sessionId: String, cwd: String?) -> String? {
        entry(sessionId, cwd)?.prompt
    }

    private static func entry(_ sessionId: String, _ cwd: String?) -> Entry? {
        guard let path = Transcript.path(sessionId: sessionId, cwd: cwd) else { return cache[sessionId] }
        let mtime = ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate]
                     as? Date) ?? .distantPast
        if let hit = cache[sessionId], hit.mtime == mtime { return hit }

        // Both lines are appended, so the tail holds the newest of each. Transcripts reach tens
        // of megabytes; reading the end is cheaper than any scan of the whole file.
        let tail = Tail.read(path: path, bytes: 512 * 1024)
        var e = Entry(mtime: mtime,
                      title: value("aiTitle", marker: "\"ai-title\"", in: tail),
                      prompt: value("lastPrompt", marker: "\"last-prompt\"", in: tail))
        // A title is written once and may have scrolled out of the tail of a long session, so
        // keep the one we already had rather than letting the row fall back to its hash.
        if e.title == nil { e.title = cache[sessionId]?.title }
        if e.prompt == nil { e.prompt = cache[sessionId]?.prompt }
        cache[sessionId] = e
        return e
    }

    /// The last line carrying `marker`, decoded for `key`.
    private static func value(_ key: String, marker: String, in text: String) -> String? {
        guard let found = text.split(whereSeparator: \.isNewline).last(where: { $0.contains(marker) }),
              let data = found.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let v = obj[key] as? String, !v.isEmpty else { return nil }
        return v.split(whereSeparator: \.isNewline).first.map(String.init) ?? v
    }
}
