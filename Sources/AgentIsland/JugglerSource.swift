import Foundation

/// Juggler conversations, from the folders it writes beside the code.
///
/// A project is found from the app's own `workspace.json`/`recents.json` or, for a headless
/// server, its `--project` argv; each one names `<project>/.juggler/`. Conversations are folders named
/// `<title>--conv_<id>`, and Juggler treats that name as the source of truth for the title, so a
/// row needs no document parsing: the conversation itself is a Yjs binary we never open.
///
/// Which conversations are mid-turn comes from `/api/health/active`, one of the handful of routes
/// Juggler deliberately leaves unauthenticated so another process can ask. Note what it will not
/// tell us: a turn parked on a pending tool approval is explicitly NOT counted as active, and that
/// state lives only inside the Yjs document — so a Juggler row can say "working", never "waiting".
struct JugglerSource: AgentSource {
    let vendor: Vendor = .juggler

    private var configDir: String {
        ProcessInfo.processInfo.environment["JUGGLER_CONFIG_DIR"] ?? Home.path + "/.juggler"
    }

    var isAvailable: Bool { FileManager.default.fileExists(atPath: configDir) }

    func discover() -> [Agent] {
        guard isAvailable else { return [] }
        let cutoff = Date().addingTimeInterval(-Self.maxAge)
        var agents: [Agent] = []

        for project in Self.projects() {
            let dir = project + "/.juggler"
            guard let convs = Self.conversations(in: dir), !convs.isEmpty else { continue }
            let inst = Self.instance(dir: dir)

            for c in convs where c.modified > cutoff {
                agents.append(Agent(
                    sessionId: c.id,
                    name: nil,
                    cwd: project,
                    // A live server means the project is open, not that this conversation is
                    // working; the document is rewritten as a turn runs, so recency is the
                    // evidence. `/api/health/active` would answer exactly and is unauthenticated,
                    // but it costs a subprocess per refresh and a refresh must spend none.
                    state: inst == nil ? nil
                        : (Date().timeIntervalSince(c.modified) < 90 ? "busy" : "idle"),
                    status: nil,
                    pid: inst?.pid,
                    vendor: .juggler,
                    lastActiveOverride: c.modified,
                    titleOverride: c.title))
            }
        }
        return agents.sorted { ($0.lastActiveOverride ?? .distantPast) > ($1.lastActiveOverride ?? .distantPast) }
    }

    // MARK: - Where the projects are

    /// Three places, because no single one covers both ways Juggler runs. The desktop app spawns
    /// its server with no `--project` at all (verified against 0.6.4: `--window=false
    /// --exit-with-parent --log-file ...`), so argv alone finds only headless servers. The app
    /// records what it opens in `workspace.json`, which is durable, and in `cache/recents.json`,
    /// which the docs say is safe to delete — so the cache is the convenience, not the index.
    static func projects() -> [String] {
        var found: Set<String> = []
        let cfg = ProcessInfo.processInfo.environment["JUGGLER_CONFIG_DIR"] ?? Home.path + "/.juggler"

        for (pid, comm) in Proc.all() where comm == "juggler" || comm == "juggler-app" {
            guard let argv = Proc.argsEnv(pid: Int(pid))?.argv,
                  let i = argv.firstIndex(of: "--project"), i + 1 < argv.count else { continue }
            found.insert(argv[i + 1])
        }
        // Open windows now.
        if let d = FileManager.default.contents(atPath: cfg + "/workspace.json"),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let windows = o["windows"] as? [[String: Any]] {
            for w in windows { (w["project"] as? String).map { found.insert($0) } }
        }
        // Recently opened, so a project you closed this morning is still a row.
        if let d = FileManager.default.contents(atPath: cfg + "/cache/recents.json"),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let paths = o["paths"] as? [String] {
            found.formUnion(paths)
        }
        return found.filter { FileManager.default.fileExists(atPath: $0 + "/.juggler") }
    }

    // MARK: - What is in a project

    struct Conversation { let id: String, title: String; let modified: Date }
    struct Instance { let pid: Int, port: Int; let host: String }

    /// Mirrors Juggler's own ScanConvDirs: a folder named `<title>--conv_<id>`, the title being
    /// everything before the LAST separator. Anything else in there is not a conversation.
    static func conversations(in dir: String) -> [Conversation]? {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        var out: [Conversation] = []
        for e in entries {
            guard let sep = e.range(of: "--", options: .backwards) else { continue }
            let id = String(e[sep.upperBound...]), title = String(e[..<sep.lowerBound])
            guard id.hasPrefix("conv_"), id.count > 5, !title.isEmpty,
                  id.dropFirst(5).allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" })
            else { continue }
            let path = dir + "/" + e
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue
            else { continue }
            // The document is rewritten on every mutation, so it dates the conversation far
            // better than the folder, which only changes when a child is added or removed.
            let doc = path + "/doc.yjs"
            let m = (try? FileManager.default.attributesOfItem(atPath: doc))?[.modificationDate] as? Date
                ?? (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            out.append(Conversation(id: id, title: title.precomposedStringWithCanonicalMapping,
                                    modified: m ?? .distantPast))
        }
        return out
    }

    static func instance(dir: String) -> Instance? {
        guard let d = FileManager.default.contents(atPath: dir + "/instance.json"),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let pid = o["pid"] as? Int, let port = o["port"] as? Int, Proc.alive(pid)
        else { return nil }
        return Instance(pid: pid, port: port, host: (o["host"] as? String) ?? "localhost")
    }

}
