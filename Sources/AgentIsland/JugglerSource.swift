import Foundation

/// Juggler conversations, from the folders it writes beside the code.
///
/// A running server advertises itself twice — `--project <path>` in its argv, and
/// `<project>/.juggler/instance.json` naming the port it bound. Conversations are folders named
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

    /// A running server carries its project in argv. `recents.json` only exists once the desktop
    /// app has opened something — the headless server never writes it — so argv is the reliable
    /// half and the MRU is a bonus that finds projects nobody has open.
    static func projects() -> [String] {
        var found: Set<String> = []
        for (pid, comm) in Proc.all() where comm == "juggler" || comm == "juggler-app" {
            guard let argv = Proc.argsEnv(pid: Int(pid))?.argv else { continue }
            if let i = argv.firstIndex(of: "--project"), i + 1 < argv.count {
                found.insert(argv[i + 1])
            }
        }
        let mru = (ProcessInfo.processInfo.environment["JUGGLER_CONFIG_DIR"]
                   ?? Home.path + "/.juggler") + "/cache/recents.json"
        if let d = FileManager.default.contents(atPath: mru),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let paths = o["paths"] as? [String] {
            for p in paths where FileManager.default.fileExists(atPath: p + "/.juggler") {
                found.insert(p)
            }
        }
        return Array(found)
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
