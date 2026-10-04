import Foundation
import SQLite3

/// MonoCode, a desktop UI for coding agents, stops an agent's process between turns. Its own table
/// of tabs carries each agent's session id, so it says which sessions live there even then.
enum MonoCode {
    static let host = HostTerminal.app(bundleID: "com.monocode.desktop", name: "MonoCode")

    private static let lock = NSLock()
    private static var cache: (stamp: Date, ids: Set<String>)?

    /// Agent session ids of MonoCode's unarchived tabs; the database is read only when it changes.
    static func sessionIDs() -> Set<String> {
        let db = Home.path + "/Library/Application Support/com.monocode.desktop/monocode.db"
        let stamp = [db, db + "-wal"].compactMap {
            (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date
        }.max()
        guard let stamp else { return [] }   // not installed: one stat, nothing opened
        lock.lock(); defer { lock.unlock() }
        if let c = cache, c.stamp == stamp { return c.ids }

        // Read-only and query-only: MonoCode must never wait on us; a busy database is tried next refresh.
        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        var stmt: OpaquePointer?
        guard sqlite3_open_v2(db, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let h = handle,
              sqlite3_busy_timeout(h, 200) == SQLITE_OK,
              sqlite3_prepare_v2(h, "SELECT provider_session_id FROM sessions WHERE archived = 0 "
                                    + "AND provider_session_id IS NOT NULL", -1, &stmt, nil) == SQLITE_OK,
              let st = stmt else { return cache?.ids ?? [] }
        defer { sqlite3_finalize(st) }
        var ids = Set<String>()
        while sqlite3_step(st) == SQLITE_ROW {
            if let t = sqlite3_column_text(st, 0) { ids.insert(String(cString: t)) }
        }
        cache = (stamp, ids)
        return ids
    }
}
