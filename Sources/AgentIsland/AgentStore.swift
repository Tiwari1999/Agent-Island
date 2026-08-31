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
    var lastActive: Date?
    var tabTitle: String?
    var tabPosition: Int?
    var aiTitle: String?
    var lastPrompt: String?
    var status: SessionStatus?
    var tasks: TaskProgress?
    var died: String?
    var id: String { agent.sessionId }

    /// Background sessions own no terminal; they are reached by attaching, not jumping.
    var isBackground: Bool { agent.pid != nil && warpURL == nil }
    /// Every row is actionable — jump to the tab, or open one and attach.
    var canJump: Bool { warpURL != nil || agent.pid != nil }

    /// A tab the user renamed wins (that is what they see), then Claude's own description of the
    /// session, and only then the generated `mono-17` style handle.
    var displayName: String { tabTitle ?? aiTitle ?? agent.label }
    /// Keep the handle visible when a real title replaced it, so rows stay cross-referenceable.
    var subtitle: String { displayName == agent.label ? agent.project : agent.label }
    /// Context pressure — the compaction cliff is at 90%.
    var contextPct: Int? { status?.contextPct }
    var nearCompaction: Bool { (status?.contextPct ?? 0) >= 90 }

    /// Where this session runs, for the row's context chips.
    var terminal: String { warpURL != nil ? "Warp" : (isBackground ? "background" : "—") }

    /// Position is only useful as a hover hint, never as the label.
    var tabHint: String {
        if let n = tabPosition { return "Warp tab \(n)" }
        return isBackground ? "background session" : "no tab"
    }
    /// A blocked agent's own question outranks any stale tool activity.
    var activity: String? { blockedQuestion ?? live?.detail }
    var blockedQuestion: String? {
        agent.phase == "blocked" ? Blocked.question(for: agent.sessionId) : nil
    }
    /// Tool name is rendered separately so it can read as a link, like the reference UI.
    var tool: String? { live?.tool }
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
    let hooks = HookStream()

    private var timer: Timer?
    private var bag = Set<AnyCancellable>()

    var workingCount: Int { rows.filter { $0.agent.isWorking }.count }
    var waitingCount: Int { rows.filter { $0.waiting }.count }
    var blockedCount: Int { rows.filter { $0.dormantBlocked }.count }
    /// The line worth showing while collapsed: whatever is happening right now.
    var nowLine: String? {
        rows.first(where: { $0.waiting })?.activity
            ?? rows.first(where: { $0.agent.isWorking && $0.activity != nil })?.activity
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
    }

    /// `claude agents --json` costs ~256ms of CPU per call — a Node process start. Polling it
    /// every 4s burned 6.4% of a core continuously just to keep a list nobody was looking at.
    /// Hooks already push state changes, so the poll only needs to be brisk while the panel is
    /// open; otherwise it is a slow backstop.
    private static let activeInterval: TimeInterval = 4
    private static let idleInterval: TimeInterval = 20
    private var panelVisible = false

    func setPanelVisible(_ visible: Bool) {
        guard visible != panelVisible else { return }
        panelVisible = visible
        if visible { refresh() }        // opening the panel should show current state at once
        reschedule()
    }

    private func reschedule() {
        timer?.invalidate()
        let interval = panelVisible ? Self.activeInterval : Self.idleInterval
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        Shell.run(Shell.claude, ["agents", "--json", "--all"]) { [weak self] out, code in
            guard let self, code == 0, let data = out.data(using: .utf8),
                  let parsed = try? JSONDecoder().decode([Agent].self, from: data) else { return }
            self.rebuild(parsed)
        }
    }

    /// Resolving Warp URLs shells out per agent, so it happens off the main actor.
    private func rebuild(_ agents: [Agent]) {
        DispatchQueue.global(qos: .utility).async {
            // One ps call for every pid we have not seen, instead of two per agent per cycle.
            let pids = agents.compactMap(\.pid)
            ProcEnv.prime(pids: pids)
            ProcEnv.retain(Set(pids))
            let resolved: [(Agent, String?, Date?, WarpTabs.Tab?)] = agents.map { a in
                (a, a.pid.flatMap { WarpJump.focusURL(pid: $0) },
                 Transcript.lastActive(a), a.pid.flatMap { WarpTabs.tab(pid: $0) })
            }
            Task { @MainActor in
                let now = Date()
                self.rows = resolved
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
                                    warpURL: $0.1, lastActive: $0.2,
                                    tabTitle: $0.3?.title, tabPosition: $0.3?.position,
                                    aiTitle: Titles.title(for: $0.0.sessionId, cwd: $0.0.cwd),
                                    lastPrompt: Titles.lastPrompt(for: $0.0.sessionId, cwd: $0.0.cwd),
                                    status: SessionStatuses.get($0.0.sessionId),
                                    tasks: Tasks.progress(for: $0.0.sessionId),
                                    died: self.hooks.failures[$0.0.sessionId]) }
                    // Purely by recency: anything working is writing to its transcript now,
                    // so it rises on its own without a state bucket pinning idle rows down.
                    .sorted { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }
            }
        }
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
        .sorted { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }
    }

    /// The name a human recognises, resolved the same way everywhere: a renamed Warp tab, then
    /// Claude's own title for the session, and only then the generated handle.
    func displayName(for sessionId: String) -> String {
        if let row = rows.first(where: { $0.agent.sessionId == sessionId }) { return row.displayName }
        if let t = Titles.title(for: sessionId, cwd: nil), !t.isEmpty { return t }
        return String(sessionId.prefix(8))
    }

    func jump(_ row: AgentRow) {
        if let pid = row.agent.pid, WarpJump.jump(pid: pid) { return }
        // A background session has no tab to focus, so open one and hand over the attach command.
        guard row.agent.pid != nil else { return }
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

    static func lastActive(_ a: Agent) -> Date? {
        guard let path = path(for: a) else { return nil }
        // The expensive part is tail+grep. If the file has not changed since we last looked,
        // neither has the answer — this was three process spawns per agent per refresh.
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]
                     as? Date) ?? .distantPast
        if let hit = activeCache[a.sessionId], hit.mtime == mtime { return hit.value }
        let tail = Shell.runSync("/bin/sh", ["-c",
            "tail -c 32768 '\(path)' 2>/dev/null | grep -o '\"timestamp\":\"[^\"]*\"' | tail -1"])
        let stamp = tail.replacingOccurrences(of: "\"timestamp\":\"", with: "")
                        .replacingOccurrences(of: "\"", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
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

    static func path(for a: Agent) -> String? {
        let fm = FileManager.default
        if let cwd = a.cwd {
            let slug = cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce(into: "") { $0.append($1) }
            let p = NSHomeDirectory() + "/.claude/projects/\(slug)/\(a.sessionId).jsonl"
            if fm.fileExists(atPath: p) { return p }
        }
        let found = Shell.runSync("/bin/sh", ["-c",
            "ls \(NSHomeDirectory())/.claude/projects/*/\(a.sessionId).jsonl 2>/dev/null | head -1"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return found.isEmpty ? nil : found
    }
}
