import Foundation

/// Resolves a Warp session UUID to the tab the user actually sees, so a row can be labelled with
/// the same name as the tab it jumps to — otherwise there is no way to confirm the jump landed.
enum WarpTabs {
    struct Tab { let position: Int; let title: String? }

    private static let db = NSHomeDirectory()
        + "/Library/Group Containers/2BBY89MBSN.dev.warp/Library/Application Support"
        + "/dev.warp.Warp-Stable/warp.sqlite"

    private static var cache: [String: Tab] = [:]
    private static var cachedAt = Date.distantPast

    /// Warp holds the DB in WAL mode, so query a snapshot rather than fighting the live file.
    static func map() -> [String: Tab] {
        if Date().timeIntervalSince(cachedAt) < 8, !cache.isEmpty { return cache }
        guard FileManager.default.fileExists(atPath: db) else { return [:] }

        let tmp = NSTemporaryDirectory() + "agentisland-warp-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        for ext in ["", "-wal", "-shm"] {
            try? FileManager.default.copyItem(atPath: db + ext, toPath: tmp + "/w.sqlite" + ext)
        }

        let sql = """
        SELECT lower(hex(tp.uuid)), pn.tab_id, ifnull(t.custom_title,'')
        FROM terminal_panes tp
        JOIN pane_nodes pn ON pn.id = tp.id
        JOIN tabs t ON t.id = pn.tab_id;
        """
        let rows = Shell.runSync("/usr/bin/sqlite3", ["-separator", "\u{1}", tmp + "/w.sqlite", sql])
        let order = Shell.runSync("/usr/bin/sqlite3", [tmp + "/w.sqlite",
                                                       "SELECT id FROM tabs ORDER BY id;"])
        // Tabs sorted by id match the visible tab-bar order, so rank gives the position shown.
        var rank: [String: Int] = [:]
        for (i, id) in order.split(whereSeparator: \.isNewline).enumerated() {
            rank[String(id)] = i + 1
        }

        var out: [String: Tab] = [:]
        for line in rows.split(whereSeparator: \.isNewline) {
            let f = line.components(separatedBy: "\u{1}")
            guard f.count >= 3 else { continue }
            let title = f[2].trimmingCharacters(in: .whitespaces)
            out[f[0]] = Tab(position: rank[f[1]] ?? 0, title: title.isEmpty ? nil : title)
        }
        if !out.isEmpty { cache = out; cachedAt = Date() }
        return out
    }

    /// The session UUID Warp exported into the agent's environment.
    static func sessionUUID(pid: Int) -> String? {
        ProcEnv.prime(pids: [pid])
        return ProcEnv.warp(pid: pid).sessionUUID?.lowercased()
    }

    static func tab(pid: Int) -> Tab? {
        guard let uuid = sessionUUID(pid: pid) else { return nil }
        return map()[uuid.replacingOccurrences(of: "-", with: "")]
    }
}
