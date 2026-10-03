import Foundation
import SQLite3

/// OpenCode sessions, from its SQLite store `~/.local/share/opencode/opencode.db` (tables
/// `session`, `message`, `part`; JSON lives in each row's `data` column).
struct OpenCodeSource: AgentSource {
    let vendor: Vendor = .opencode

    // OpenCode reads XDG_DATA_HOME, but this app is launched by launchd and never sees a shell's.
    private var db: String { Home.path + "/.local/share/opencode/opencode.db" }

    var isAvailable: Bool { FileManager.default.fileExists(atPath: db) }

    func discover() -> [Agent] {
        guard isAvailable else { return [] }
        // WAL mode: a write lands in -wal long before the main file's mtime moves.
        let stamp = [db, db + "-wal"].compactMap {
            (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date
        }.max() ?? .distantPast
        let sessions: [Session]
        if let hit = Self.cache, hit.stamp == stamp { sessions = hit.value } else {
            sessions = Self.read(path: db, since: Date().addingTimeInterval(-Self.maxAge))
            Self.cache = (stamp, sessions)
        }

        let running = Cwd.map(pids: Proc.leaves(Proc.pids(named: ["opencode"])))
        var claimed = Set<Int>()
        return sessions.compactMap { s in
            if !s.cwd.isEmpty, !FileManager.default.fileExists(atPath: s.cwd) { return nil }
            var live = running[s.cwd]
            if let p = live, claimed.contains(p) { live = nil }
            if let p = live { claimed.insert(p) }
            return Agent(
                sessionId: s.id,
                name: s.title,
                cwd: s.cwd.isEmpty ? nil : s.cwd,
                // An assistant message without `time.completed` is a turn still generating.
                state: live == nil ? nil : (s.generating ? "busy" : "idle"),
                status: nil,
                pid: live,
                vendor: .opencode,
                lastActiveOverride: s.updated,
                titleOverride: s.firstPrompt
                    ?? (s.cwd as NSString).lastPathComponent + " session",
                promptOverride: s.lastPrompt)
        }
    }

    struct Session: Equatable {
        let id: String
        let cwd: String
        let title: String?
        let updated: Date
        var firstPrompt: String?
        var lastPrompt: String?
        var generating = false
    }

    private static var cache: (stamp: Date, value: [Session])?

    /// Read-only and query-only: the store belongs to a running opencode, which must never wait
    /// on us, and a busy database is just tried again next refresh.
    static func read(path: String, since: Date) -> [Session] {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db = handle else { sqlite3_close(handle); return [] }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)

        func rows(_ sql: String, _ bind: [Any], _ each: (OpaquePointer) -> Void) {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let st = stmt else { return }
            defer { sqlite3_finalize(st) }
            for (i, v) in bind.enumerated() {
                if let s = v as? String { sqlite3_bind_text(st, Int32(i + 1), s, -1, transient) }
                if let n = v as? Int64 { sqlite3_bind_int64(st, Int32(i + 1), n) }
            }
            while sqlite3_step(st) == SQLITE_ROW { each(st) }
        }
        func text(_ st: OpaquePointer, _ col: Int32) -> String? {
            sqlite3_column_text(st, col).map { String(cString: $0) }
        }

        // Child sessions are subagents (parent_id); their work already shows on the parent's row.
        var out: [Session] = []
        rows("""
            SELECT id, directory, title, time_updated FROM session
            WHERE parent_id IS NULL AND time_archived IS NULL AND time_updated > ?
            ORDER BY time_updated DESC LIMIT 200
            """, [Int64(since.timeIntervalSince1970 * 1000)]) { st in
            let title = text(st, 2) ?? ""
            out.append(Session(
                id: text(st, 0) ?? "", cwd: text(st, 1) ?? "",
                // The placeholder OpenCode writes until it has named the chat is not a name.
                title: title.isEmpty || title.hasPrefix("New session - ") ? nil : title,
                updated: Date(timeIntervalSince1970: Double(sqlite3_column_int64(st, 3)) / 1000)))
        }
        let prompt = """
            SELECT json_extract(p.data, '$.text') FROM part p JOIN message m ON m.id = p.message_id
            WHERE p.session_id = ? AND json_extract(m.data, '$.role') = 'user'
              AND json_extract(p.data, '$.type') = 'text'
              AND coalesce(json_extract(p.data, '$.synthetic'), 0) = 0
            ORDER BY p.time_created %@, p.id %@ LIMIT 1
            """
        for i in out.indices {
            let id = out[i].id
            rows(String(format: prompt, "ASC", "ASC"), [id]) { st in
                out[i].firstPrompt = text(st, 0).flatMap(PromptText.humanLine).map { String($0.prefix(60)) }
            }
            rows(String(format: prompt, "DESC", "DESC"), [id]) { st in
                out[i].lastPrompt = text(st, 0).flatMap(PromptText.humanLine).map {
                    $0.count > 120 ? String($0.prefix(120)) + "…" : $0 }
            }
            rows("""
                SELECT json_extract(data, '$.role'), json_extract(data, '$.time.completed')
                FROM message WHERE session_id = ? ORDER BY time_created DESC, id DESC LIMIT 1
                """, [id]) { st in
                out[i].generating = text(st, 0) == "assistant"
                    && sqlite3_column_type(st, 1) == SQLITE_NULL
            }
        }
        return out
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
