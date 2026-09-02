import AppKit
import Combine
import Foundation

struct Agent: Identifiable, Decodable {
    let sessionId: String
    let name: String?
    let cwd: String?
    let state: String?
    let status: String?
    let pid: Int?

    /// Which tool is running this session. Absent when decoded from Claude's JSON, which
    /// predates multi-vendor support and does not report one.
    var vendor: Vendor = .claude
    /// Vendors other than Claude carry their own metadata, so they supply these at discovery
    /// rather than having them dug out of a transcript afterwards.
    var lastActiveOverride: Date?
    var titleOverride: String?
    var promptOverride: String?
    /// Vendors without a statusLine report context pressure at discovery instead.
    var contextPctOverride: Int?
    /// Set when this session lives on a machine reached over ssh.
    var remoteHost: String?

    enum CodingKeys: String, CodingKey {
        case sessionId, name, cwd, state, status, pid
    }

    init(sessionId: String, name: String?, cwd: String?, state: String?, status: String?,
         pid: Int?, vendor: Vendor = .claude, lastActiveOverride: Date? = nil,
         titleOverride: String? = nil, promptOverride: String? = nil,
         contextPctOverride: Int? = nil, remoteHost: String? = nil) {
        self.sessionId = sessionId
        self.name = name
        self.cwd = cwd
        self.state = state
        self.status = status
        self.pid = pid
        self.vendor = vendor
        self.lastActiveOverride = lastActiveOverride
        self.titleOverride = titleOverride
        self.promptOverride = promptOverride
        self.contextPctOverride = contextPctOverride
        self.remoteHost = remoteHost
    }

    var id: String { sessionId }
    var label: String { name ?? String(sessionId.prefix(8)) }
    var project: String { (cwd as NSString?)?.lastPathComponent ?? "—" }
    /// Background sessions report `state`, interactive ones `status`.
    var phase: String { state ?? status ?? "unknown" }
    var isWorking: Bool { phase == "busy" || phase == "running" }
    var isPaused: Bool { phase == "blocked" || phase == "failed" }
}

struct AgentRow: Identifiable {
    let agent: Agent
    var live: LiveState?
    var warpURL: String?
    var host: HostTerminal = .unknown
    var lastActive: Date?
    var aiTitle: String?
    var lastPrompt: String?
    var status: SessionStatus?
    var tasks: TaskProgress?
    var died: String?
    /// The agent's own last sentence, shown while it is thinking rather than calling a tool.
    var narration: String?
    var id: String { agent.sessionId }

    /// A session with no reachable host is attached to, not jumped to.
    var isBackground: Bool { agent.pid != nil && !host.canReach }
    /// Every row does something: focus a live tab, open a workspace, or offer the resume
    /// command. Only a session whose vendor has no resume path is truly inert.
    var canJump: Bool { agent.pid != nil || Reopen.command(for: agent) != nil }
    /// True when we can land on the exact tab rather than merely raising the app.
    var precise: Bool { host.isPrecise }

    /// The agent's own description of the session, and only then the generated `mono-17` handle.
    var displayName: String { aiTitle ?? agent.label }
    /// Keep the handle visible when a real title replaced it, so rows stay cross-referenceable.
    var subtitle: String { displayName == agent.label ? agent.project : agent.label }
    /// What this row cannot show, because its vendor does not publish it. Shown in place of a
    /// blank, so an unsupported capability never reads as a broken one.
    var unsupported: String? {
        switch agent.vendor {
        case .claude: return nil
        case .codex:  return tasks == nil ? "no task list" : nil
        case .cursor: return "no quota data"
        }
    }

    /// Context pressure — the compaction cliff is at 90%.
    var contextPct: Int? { agent.contextPctOverride ?? status?.contextPct }
    var nearCompaction: Bool { (status?.contextPct ?? 0) >= 90 }

    /// Where this session runs, for the row's context chip.
    var terminal: String { host.name }

    var tabHint: String { isBackground ? "background session" : host.name }
    /// A blocked agent's own question outranks any stale tool activity.
    var activity: String? {
        if let q = blockedQuestion { return q }
        guard isWorking else { return nil }   // finished work is not current activity
        return live?.detail ?? narration
    }
    var blockedQuestion: String? {
        agent.phase == "blocked" ? Blocked.question(for: agent.sessionId) : nil
    }
    /// Tool name is rendered separately so it can read as a link, like the reference UI.
    var tool: String? { live?.tool }

    /// A hook that says the turn ended is exact. The transcript-mtime guess behind
    /// `agent.isWorking` is not: finishing a turn writes to the transcript, so it reported
    /// "busy" for two minutes after every agent went quiet.
    ///
    /// Hook state can also outlive the process that produced it — a session that ends without a
    /// final Stop leaves its last event saying "active" — so a row with no live process is never
    /// working, whatever the spool remembers. Under-reporting beats claiming work that is over.
    var isWorking: Bool {
        guard agent.pid != nil || agent.remoteHost != nil else { return false }
        // Once hooks report for a session they are the authority, and a working agent emits one
        // every few seconds: a claim this old is a turn that ended without a final Stop, not
        // work still running. Only a session with no hook data at all falls back to the
        // vendor's own guess, which for Claude is the transcript's mtime.
        if let l = live { return l.active && Date().timeIntervalSince(l.at) < 90 }
        return agent.isWorking
    }

    /// What the agent is actually doing right now, from the tool it last announced. The bar
    /// animates this, so "thinking" and "editing files" no longer look identical.
    var workKind: WorkKind {
        if waiting || dormantBlocked { return .waiting }
        guard isWorking else { return .idle }
        switch tool {
        case "Edit", "Write", "NotebookEdit", "MultiEdit", "str_replace_editor":
            return .writing
        case "Bash", "Shell", "run_terminal_cmd", "BashOutput":
            return .running
        case "Read", "Grep", "Glob", "LS", "read_file", "list_dir", "codebase_search":
            return .reading
        case "WebFetch", "WebSearch", "web_search":
            return .searching
        case "Task", "Agent":
            return .delegating
        default:
            // No tool in flight means the model is between calls: thinking.
            return tool == nil ? .thinking : .running
        }
    }
    /// Needs you *right now*: a hook fired inside the live window. This is what earns an alarm.
    var waiting: Bool { live?.waiting ?? false }
    /// Blocked on a question asked long ago. Real work, but not urgent — counting it as
    /// "waiting" made the header claim attention was needed when nothing had just happened.
    var dormantBlocked: Bool { blockedQuestion != nil && !(live?.waiting ?? false) }

    var ago: String {
        guard let lastActive else { return "" }
        let s = Date().timeIntervalSince(lastActive)
        if s < 45 { return "now" }
        if s < 3600 { return "\(Int(s/60))m" }
        if s < 86400 { return "\(Int(s/3600))h" }
        return "\(Int(s/86400))d"
    }
}

@MainActor
final class AgentStore: ObservableObject {
    @Published private(set) var rows: [AgentRow] = []
    /// False until discovery has completed once, so the empty state can tell "nothing yet" from
    /// "nothing at all".
    @Published private(set) var hasRefreshed = false
    let hooks = HookStream()

    private var timer: Timer?
    private var bag = Set<AnyCancellable>()

    var workingCount: Int { rows.filter { $0.isWorking }.count }
    var waitingCount: Int { rows.filter { $0.waiting }.count }
    var blockedCount: Int { rows.filter { $0.dormantBlocked }.count }
    /// The line worth showing while collapsed: whatever is happening right now.
    var nowLine: String? {
        rows.first(where: { $0.waiting })?.activity
            ?? rows.first(where: { $0.isWorking && $0.activity != nil })?.activity
            ?? rows.first(where: { $0.activity != nil })?.activity
    }

    func start() {
        hooks.start()
        hooks.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyLive() }
            .store(in: &bag)
        refresh()
        reschedule()
        startWatching()
    }

    /// `claude agents --json` costs ~256ms of CPU per call — a Node process start. Polling it
    /// every 4s burned 6.4% of a core continuously just to keep a list nobody was looking at.
    /// Hooks push state changes and the watcher reports writes, so the timer is only a backstop
    /// for what neither can see — a process exiting without a hook firing. It does not need to be
    /// brisk, and being brisk is expensive: each cycle spawns a Node process to ask Claude Code
    /// for its sessions.
    private static let activeInterval: TimeInterval = 15
    private static let idleInterval: TimeInterval = 180
    private var watcher: SourceWatcher?

    /// Watch what every vendor writes to. Directories that do not exist are skipped, so a machine
    /// without Codex or Cursor installed simply watches fewer trees.
    func startWatching() {
        let home = Home.path
        watcher = SourceWatcher(paths: [
            home + "/.claude/projects", home + "/.claude/jobs",
            home + "/.codex/sessions", home + "/.cursor/chats",
        ]) { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        watcher?.start()
    }
    private var panelVisible = false

    /// While the panel is open, rows keep the order they were opened with: re-sorting a live
    /// list under the cursor turns the row you are about to click into a different session.
    /// New sessions still appear — appended, not interleaved.
    private var frozenOrder: [String: Int] = [:]

    private func applyOrder(_ rows: [AgentRow]) -> [AgentRow] {
        let sorted = rows.sorted { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }
        guard panelVisible, !frozenOrder.isEmpty else { return sorted }
        return sorted.sorted {
            (frozenOrder[$0.agent.sessionId] ?? Int.max) < (frozenOrder[$1.agent.sessionId] ?? Int.max)
        }
    }

    func setPanelVisible(_ visible: Bool) {
        guard visible != panelVisible else { return }
        panelVisible = visible
        if visible {
            frozenOrder = Dictionary(uniqueKeysWithValues:
                rows.enumerated().map { ($0.element.agent.sessionId, $0.offset) })
            refresh(); refreshCosts()   // current state at once, money lazily
        } else {
            frozenOrder = [:]
        }
        reschedule()
    }

    /// The month's cost table. The first scan reads every transcript touched this month (~4s of
    /// CPU), so it runs off-main, at most once a minute, and only while someone is looking.
    @Published var costTable: Costs.Table = [:]
    private var costsAt = Date.distantPast

    func refreshCosts() {
        guard Date().timeIntervalSince(costsAt) > 60 else { return }
        costsAt = Date()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let t = Costs.scan()
            Task { @MainActor in self?.costTable = t }
        }
    }

    private func reschedule() {
        timer?.invalidate()
        let interval = panelVisible ? Self.activeInterval : Self.idleInterval
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Every vendor present on the machine. Absent tools cost nothing — `isAvailable` is a
    /// file check — so this list can grow without a settings switch.
    private let sources: [AgentSource] = [ClaudeSource(), CodexSource(), CursorSource(), RemoteSource()]

    /// Discovery mutates each vendor's static caches, so exactly one may be in flight. This also
    /// stops polls from stacking up behind a slow one — the shape that made a single wedged
    /// syscall freeze every later refresh.
    private var refreshing = false

    private var lastRefreshAt = Date.distantPast
    private var coalescing: Timer?

    /// The shortest gap the watcher may drive. A hundred agents writing at once must not mean a
    /// hundred refreshes — the floor turns any burst into a single one, and nothing is dropped:
    /// an event arriving inside the window schedules the refresh at its far edge.
    private var refreshFloor: TimeInterval { panelVisible ? 4 : 20 }

    func refreshSoon() {
        let due = lastRefreshAt.addingTimeInterval(refreshFloor)
        if Date() >= due { refresh(); return }
        guard coalescing == nil else { return }
        coalescing = Timer.scheduledTimer(withTimeInterval: due.timeIntervalSinceNow,
                                          repeats: false) { [weak self] _ in
            Task { @MainActor in self?.coalescing = nil; self?.refresh() }
        }
    }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        lastRefreshAt = Date()
        // Snapshot the sources on the main actor; the discovery work itself is off it.
        let sources = self.sources
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let started = Date()
            let perSource = sources.filter(\.isAvailable).map { src -> (Vendor, [Agent], Double) in
                let t = Date()
                let found = src.discover()
                return (src.vendor, found, Date().timeIntervalSince(t))
            }
            let found = perSource.flatMap { $0.1 }
            Diagnostics.log("refresh: \(found.count) sessions in "
                + String(format: "%.2fs", Date().timeIntervalSince(started))
                + " [" + perSource.map {
                    String(format: "%@ %d/%.2fs", $0.0.rawValue, $0.1.count, $0.2)
                  }.joined(separator: ", ") + "] "
                + Shell.spawnsSinceLastCheck())
            Task { @MainActor in
                self?.hasRefreshed = true
                // Cleared by rebuild once the rows are published: releasing it here let the next
                // refresh overtake a slow rebuild and publish an older set over a newer one.
                self?.rebuild(found)
            }
        }
    }

    /// Resolving Warp URLs shells out per agent, so it happens off the main actor.
    private func rebuild(_ agents: [Agent]) {
        DispatchQueue.global(qos: .utility).async {
            // One ps call for every pid we have not seen, instead of two per agent per cycle.
            let pids = agents.compactMap(\.pid)
            ProcEnv.prime(pids: pids)
            // Every per-process and per-session cache is bounded to what is currently live.
            // Without this they grow for the life of the app — invisible in a 60-second
            // benchmark, and a real leak over a day of agents starting and stopping.
            let alive = Set(pids)
            ProcEnv.retain(alive)
            Cwd.retain(alive)
            let ids = Set(agents.map(\.sessionId))
            Transcript.retain(ids)
            Titles.retain(ids)
            Narration.retain(ids)
            let resolved: [(Agent, String?, Date?, HostTerminal)] = agents.map { a in
                (a, a.pid.flatMap { WarpJump.focusURL(pid: $0) },
                 a.lastActiveOverride ?? Transcript.lastActive(a),
                 a.pid.map { HostTerminal.resolve(pid: $0) } ?? .unknown)
            }
            Task { @MainActor in
                let now = Date()
                let built = resolved
                    .filter { agent, _, lastActive, _ in
                        if agent.isWorking { return true }
                        // A blocked agent is waiting on a human. Hiding it for being old is how
                        // two real work items sat unanswered for months.
                        if agent.phase == "blocked" { return true }
                        guard let lastActive else { return false }
                        return now.timeIntervalSince(lastActive) <= Self.maxAge
                    }
                    .map { AgentRow(agent: $0.0,
                                    live: self.hooks.live[$0.0.sessionId].flatMap {
                                        Date().timeIntervalSince($0.at) < Self.liveWindow ? $0 : nil },
                                    warpURL: $0.1, host: $0.3, lastActive: $0.2,
                                    aiTitle: $0.0.titleOverride
                                        ?? Titles.title(for: $0.0.sessionId, cwd: $0.0.cwd),
                                    lastPrompt: $0.0.promptOverride
                                        ?? Titles.lastPrompt(for: $0.0.sessionId, cwd: $0.0.cwd),
                                    status: SessionStatuses.get($0.0.sessionId),
                                    tasks: Tasks.progress(for: $0.0.sessionId),
                                    died: self.hooks.failures[$0.0.sessionId],
                                    // Only for rows with nothing in flight: one cached tail
                                    // read, and only when there is a gap worth filling.
                                    narration: (self.hooks.live[$0.0.sessionId]?.tool == nil
                                                && $0.0.isWorking)
                                        ? Narration.line(session: $0.0.sessionId, cwd: $0.0.cwd)
                                        : nil) }
                // Recency by default; frozen to the opening order while the panel is visible.
                self.rows = self.applyOrder(built)
                self.refreshing = false
                Self.publishManifest(self.rows)
            }
        }
    }

    /// What the panel is currently showing, on disk, so it can be checked without a human
    /// reading the screen — the only way to assert that no row is placeholder or stale data.
    private static func publishManifest(_ rows: [AgentRow]) {
        let items = rows.map { r -> [String: Any] in
            ["sessionId": r.agent.sessionId, "vendor": r.agent.vendor.rawValue,
             "title": r.displayName, "cwd": r.agent.cwd ?? "",
             "lastActive": r.lastActive.map { ISO8601DateFormatter().string(from: $0) } ?? "",
             "blocked": r.dormantBlocked, "working": r.isWorking,
             "context": r.contextPct ?? -1, "remote": r.agent.remoteHost ?? "",
             "pid": r.agent.pid ?? -1]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: items) else { return }
        // Row titles are the user's own prompts and /tmp is world-readable, so the file is
        // created private and then moved into place: writing first and tightening after left a
        // window in which anyone could read it.
        let path = "/tmp/agentisland.rows.json"
        let tmp = path + ".new"
        let fm = FileManager.default
        fm.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: 0o600])
        _ = try? fm.replaceItemAt(URL(fileURLWithPath: path), withItemAt: URL(fileURLWithPath: tmp))
    }

    /// Hook state older than this is history, not "now" — without an expiry a single stale
    /// event pins a dormant session to the top of the list forever.
    private static let liveWindow: TimeInterval = 180
    /// Sessions untouched for longer than this are history. Resuming one updates its transcript,
    /// so it reappears on its own — no need to carry a permanently growing list.
    private static let maxAge: TimeInterval = 10 * 24 * 3600

    private func applyLive() {
        let now = Date()
        rows = rows.map { row in
            var r = row
            if let l = hooks.live[row.agent.sessionId],
               now.timeIntervalSince(l.at) < Self.liveWindow {
                r.live = l
                if l.at > (r.lastActive ?? .distantPast) { r.lastActive = l.at }
            } else {
                r.live = nil
            }
            return r
        }
        rows = applyOrder(rows)
    }

    /// The name a human recognises, resolved the same way everywhere: a renamed Warp tab, then
    /// Claude's own title for the session, and only then the generated handle.
    func displayName(for sessionId: String) -> String {
        if let row = rows.first(where: { $0.agent.sessionId == sessionId }) { return row.displayName }
        if let t = Titles.title(for: sessionId, cwd: nil), !t.isEmpty { return t }
        return String(sessionId.prefix(8))
    }

    func jump(_ row: AgentRow) {
        // Whatever host it runs in — Warp, iTerm2, Terminal, an IDE — try that first.
        if row.host.jump() { return }
        // Could not land precisely: hand over the working directory rather than guessing.
        if case .degraded = row.host, let cwd = row.agent.cwd {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(cwd, forType: .string)
            onBackgroundAttach?("\(row.displayName) — path copied, session not resolvable")
            return
        }
        guard row.agent.pid != nil else { return }
        guard row.agent.vendor == .claude else { return }   // only Claude has an attach command
        let cmd = "\(Shell.claude) attach \(String(row.agent.sessionId.prefix(8)))"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)
        if let u = URL(string: "warp://action/new_tab") { NSWorkspace.shared.open(u) }
        // A silent clipboard write is indistinguishable from a dead button.
        onBackgroundAttach?(row.displayName)
    }

    /// Announced by the island so the user knows a command is waiting on the clipboard.
    var onBackgroundAttach: ((String) -> Void)?
}

enum Transcript {
    /// When the session last actually *said* something.
    ///
    /// mtime is the wrong signal: a long-dead session whose `claude` process is still alive gets
    /// its transcript touched without any new content, so a 25-day-old conversation reported
    /// minutes. The last entry's own timestamp cannot be faked that way.
    private static var activeCache: [String: (mtime: Date, value: Date?)] = [:]

    /// Drop entries for sessions that are no longer listed.
    static func retain(_ ids: Set<String>) {
        activeCache = activeCache.filter { ids.contains($0.key) }
        pathCache = pathCache.filter { ids.contains($0.key) }
    }

    static func lastActive(_ a: Agent) -> Date? {
        guard let path = path(for: a) else { return nil }
        // The expensive part is tail+grep. If the file has not changed since we last looked,
        // neither has the answer — this was three process spawns per agent per refresh.
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]
                     as? Date) ?? .distantPast
        if let hit = activeCache[a.sessionId], hit.mtime == mtime { return hit.value }
        let stamp = Tail.lastValue(of: "timestamp", in: Tail.read(path: path, bytes: 32768)) ?? ""
        if !stamp.isEmpty {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = iso.date(from: stamp) { activeCache[a.sessionId] = (mtime, d); return d }
            iso.formatOptions = [.withInternetDateTime]
            if let d = iso.date(from: stamp) { activeCache[a.sessionId] = (mtime, d); return d }
        }
        // Only fall back to mtime when the transcript carries no timestamps at all.
        activeCache[a.sessionId] = (mtime, mtime)
        return mtime
    }

    /// A transcript never moves, so the answer — including "there isn't one" — is resolved once.
    /// The fallback used to shell out per session per refresh, which at a hundred agents is a
    /// hundred process spawns every cycle for a path that cannot have changed.
    private static var pathCache: [String: String] = [:]

    static func path(for a: Agent) -> String? { path(sessionId: a.sessionId, cwd: a.cwd) }

    static func path(sessionId: String, cwd: String?) -> String? {
        if let hit = pathCache[sessionId] { return hit.isEmpty ? nil : hit }
        let fm = FileManager.default
        let projects = Home.path + "/.claude/projects"
        if let cwd {
            let slug = cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce(into: "") { $0.append($1) }
            let p = "\(projects)/\(slug)/\(sessionId).jsonl"
            if fm.fileExists(atPath: p) { pathCache[sessionId] = p; return p }
        }
        // Scanning the project directories costs stats, not processes.
        for dir in (try? fm.contentsOfDirectory(atPath: projects)) ?? [] {
            let p = "\(projects)/\(dir)/\(sessionId).jsonl"
            if fm.fileExists(atPath: p) { pathCache[sessionId] = p; return p }
        }
        pathCache[sessionId] = ""
        return nil
    }
}
