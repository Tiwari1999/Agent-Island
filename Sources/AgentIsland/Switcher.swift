import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Nonactivating yet keyable: it takes the keyboard while the app behind stays active, so closing
/// it hands focus straight back without an app switch.
private final class SwitcherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class SwitcherModel: ObservableObject {
    // Only a real edit resets the pick: a text field may write its binding back unchanged.
    @Published var query = "" { didSet { if query != oldValue { selectedId = nil } } }
    /// By session, not index: rows re-sort on refresh, and an index would drift onto another session.
    @Published var selectedId: String?
    /// Recency rank taken at open, so rows and their ⌘ numbers hold still while you look.
    var order: [String: Int] = [:]
    @Published private(set) var colors = UserDefaults.standard.dictionary(forKey: "switcherColors") as? [String: Int] ?? [:]

    /// Pruned to sessions the store still knows, so tags never outlive their sessions.
    func tag(_ id: String, _ color: Int?, keeping ids: Set<String>) {
        colors[id] = color
        colors = colors.filter { ids.contains($0.key) }
        UserDefaults.standard.set(colors, forKey: "switcherColors")
    }
}

/// Finder's tag colours, so the meaning carries over: ⌥1–6 in order, ⌥0 clears.
enum SessionTag {
    static let names = ["red", "orange", "yellow", "green", "blue", "purple"]
    static let colors: [Color] = [.red, .orange, .yellow, .green, .blue, .purple]
    static func name(_ i: Int?) -> String? { i.flatMap { names.indices.contains($0) ? names[$0] : nil } }
    static func color(_ i: Int?) -> Color? { i.flatMap { colors.indices.contains($0) ? colors[$0] : nil } }
}

/// Raycast-style session picker, centred on the active screen: a filterable list on the left,
/// the selected session's details and recent transcript on the right.
@MainActor
final class Switcher {
    static let size = NSSize(width: 820, height: 500)
    private let store: AgentStore
    private let model = SwitcherModel()
    private var panel: SwitcherPanel?
    private var keyMonitor: Any?

    init(store: AgentStore) { self.store = store }

    func install() {
        // ⌘⌥ like the island's other chords; ⌘⇧Space is Trigger Parameter Hints in VS Code and Cursor.
        Hotkeys.shared.bindLasting([(kVK_ANSI_O, Hotkeys.cmdOpt, { [weak self] in self?.toggle() })])
    }

    func toggle() { panel?.isVisible == true ? close() : open() }

    nonisolated static func filter(_ rows: [AgentRow], _ query: String,
                                   _ colors: [String: Int] = [:]) -> [AgentRow] {
        let terms = query.lowercased().split(separator: " ")
        guard !terms.isEmpty else { return rows }
        return rows.filter { row in
            let hay = [row.displayName, row.agent.project, row.git?.branch ?? "", row.terminal,
                       SessionTag.name(colors[row.id]) ?? ""]
                .joined(separator: " ").lowercased()
            return terms.allSatisfy { hay.contains($0) }
        }
    }

    /// Running sessions only: picking a closed row resumes it in a NEW terminal, which is not a switch.
    static func visible(_ store: AgentStore, _ model: SwitcherModel) -> [AgentRow] {
        let open = store.rows.filter { $0.agent.pid != nil || $0.agent.remoteHost != nil }
            .sorted { (model.order[$0.id] ?? .max) < (model.order[$1.id] ?? .max) }
        return filter(open, model.query, model.colors)
    }

    private func open() {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
                ?? NSScreen.main else { return }
        let p = panel ?? makePanel()
        let v = screen.visibleFrame
        // Top fifth down, where Spotlight and Raycast sit.
        p.setFrameOrigin(NSPoint(x: v.midX - Self.size.width / 2,
                                 y: v.maxY - v.height * 0.2 - Self.size.height))
        model.query = ""
        model.selectedId = nil
        model.order = Dictionary(store.rows
            .sorted { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }
            .enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        // A fresh view per open: focus is only taken in onAppear, a runloop after the panel is key.
        p.contentView = NSHostingView(rootView: SwitcherView(store: store, model: model,
                                                             open: { [weak self] in self?.pick($0) }))
        p.makeKeyAndOrderFront(nil)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.handle(e) else { return e }
            return nil
        }
    }

    func close() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        guard panel?.isVisible == true else { return }
        panel?.orderOut(nil)
        NSApp.deactivate()
    }

    private func makePanel() -> SwitcherPanel {
        let p = SwitcherPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isExcludedFromWindowsMenu = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                               object: p, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.close() }
        }
        panel = p
        return p
    }

    private func handle(_ e: NSEvent) -> Bool {
        let rows = Self.visible(store, model)
        let i = rows.firstIndex { $0.id == model.selectedId } ?? 0
        func at(_ n: Int) -> AgentRow? { rows.indices.contains(n) ? rows[n] : nil }
        switch Int(e.keyCode) {
        case kVK_Escape: close()
        case kVK_DownArrow: model.selectedId = at(min(i + 1, rows.count - 1))?.id
        case kVK_UpArrow: model.selectedId = at(max(i - 1, 0))?.id
        case kVK_Return, kVK_ANSI_KeypadEnter: at(i).map(pick)
        default:
            let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard let n = Int(e.charactersIgnoringModifiers ?? "") else { return false }
            if mods == .command, (1...9).contains(n) {
                at(n - 1).map(pick)
            } else if mods == .option, n <= SessionTag.names.count, let row = at(i) {
                model.selectedId = row.id
                model.tag(row.id, n == 0 ? nil : n - 1, keeping: Set(store.rows.map(\.id)))
            } else {
                return false
            }
        }
        return true
    }

    private func pick(_ row: AgentRow) {
        Diagnostics.log("switcher pick \(row.id.prefix(8))")
        close()
        store.jumpToTerminal(row)
    }
}

private struct SwitcherView: View {
    @ObservedObject var store: AgentStore
    @ObservedObject var model: SwitcherModel
    let open: (AgentRow) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        let rows = Switcher.visible(store, model)
        let current = rows.first { $0.id == model.selectedId } ?? rows.first
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 16)).foregroundColor(Theme.muted)
                TextField("Search sessions", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18))
                    .foregroundColor(Theme.text)
                    .focused($focused)
            }
            .padding(.horizontal, 16)
            .frame(height: 54)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            HStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                                SwitcherRow(row: row, index: i, selected: row.id == current?.id,
                                            tag: SessionTag.color(model.colors[row.id]))
                                    .onTapGesture(count: 2) { open(row) }
                                    .onTapGesture { model.selectedId = row.id }
                            }
                        }
                        .padding(6)
                    }
                    .onChange(of: model.selectedId) { _, id in if let id { proxy.scrollTo(id) } }
                }
                .frame(width: Switcher.size.width * 0.3)
                Rectangle().fill(Theme.hairline).frame(width: 1)
                if let current {
                    SwitcherDetail(row: current)
                } else {
                    Text(model.query.isEmpty ? "No running sessions" : "No match")
                        .font(Theme.name(Type.title)).foregroundColor(Theme.faint)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Rectangle().fill(Theme.hairline).frame(height: 1)
            Text("↵ open in terminal    ↑↓ move    ⌘1–9 open    ⌥1–6 color  ⌥0 clear    esc close")
                .font(Theme.mono(Type.small)).foregroundColor(Theme.faint)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 14)
                .frame(height: 30)
        }
        .frame(width: Switcher.size.width, height: Switcher.size.height)
        .background(Theme.bg)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.hairline))
        .onAppear { DispatchQueue.main.async { focused = true } }
    }
}

private struct SwitcherRow: View {
    let row: AgentRow
    let index: Int
    let selected: Bool
    let tag: Color?

    var body: some View {
        HStack(spacing: 10) {
            Dot(color: row.tint, size: 7, pulse: row.waiting)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.displayName).font(Theme.name(Type.title)).foregroundColor(Theme.text).lineLimit(1)
                Text(([row.agent.project, row.git?.branch] as [String?]).compactMap { $0 }
                        .joined(separator: " · "))
                    .font(Theme.mono(Type.small)).foregroundColor(Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 6)
            if index < 9 {
                Text("⌘\(index + 1)").font(Theme.mono(Type.small)).foregroundColor(Theme.faint)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 46)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(selected ? Color.white.opacity(0.11) : (tag?.opacity(0.08) ?? .clear)))
        .overlay(alignment: .leading) {
            if let tag { Capsule().fill(tag).frame(width: 4).padding(.vertical, 8) }
        }
        .contentShape(Rectangle())
    }
}

/// The quick look: what the session is, where it runs, and the tail of what it said and ran.
private struct SwitcherDetail: View {
    let row: AgentRow
    @ViewState private var feed: [ChatLine] = []
    private static let ago = RelativeDateTimeFormatter()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            (Text(status).foregroundColor(row.tint) + Text("  ·  " + facts).foregroundColor(Theme.muted))
                .font(Theme.mono(Type.small))
                .lineLimit(1).truncationMode(.tail)
                .padding(.horizontal, 16)
                .frame(height: 36)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    // Not lazy: scrolling a lazy stack to its end lands on rows not yet laid out.
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(feed.enumerated()), id: \.offset) { bubble($1) }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: feed) { _, _ in
                    DispatchQueue.main.async { proxy.scrollTo("end", anchor: .bottom) }
                }
            }
        }
        .task(id: row.id) { feed = await Self.load(row) }
    }

    private var status: String {
        if row.waiting { return "waiting for you" }
        if row.isWorking { return "working" }
        if row.blockedQuestion != nil { return "blocked" }
        if row.died != nil { return "died" }
        return "idle"
    }

    private var facts: String {
        ([row.agent.project, row.git?.branch, row.terminal, row.status?.model,
          row.contextPct.map { "ctx \($0)%" }, row.tasks?.label,
          row.lastActive.map { Self.ago.localizedString(for: $0, relativeTo: Date()) }] as [String?])
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// Chat layout: you on the right in a bubble, Claude on the left, tool calls a single faint count.
    @ViewBuilder
    private func bubble(_ line: ChatLine) -> some View {
        switch line {
        case .you(let t):
            Text(t)
                .font(Theme.name(Type.body)).foregroundColor(Theme.text)
                .lineLimit(6)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.1)))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 60)
        case .claude(let t):
            MarkdownLite(text: t, style: .reading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 30)
        case .tools(let n):
            Text("⋯ \(n) tool call\(n == 1 ? "" : "s")")
                .font(Theme.mono(Type.micro)).foregroundColor(Theme.faint)
        }
    }

    /// A transcript tail costs tens of milliseconds on a big session, so never on the main actor.
    private static func load(_ row: AgentRow) async -> [ChatLine] {
        let id = row.id, cwd = row.agent.cwd
        return await withCheckedContinuation { k in
            DispatchQueue.global(qos: .userInitiated).async {
                k.resume(returning: Chat.recent(session: id, cwd: cwd))
            }
        }
    }
}

enum ChatLine: Equatable {
    case you(String), claude(String), tools(Int)
}

/// The conversation as a person reads it: your prompts and Claude's replies. Tool calls collapse to
/// a count, and meta lines, sidechains, tool output and injected `<...>` blocks are dropped.
enum Chat {
    static func recent(session: String, cwd: String?) -> [ChatLine] {
        guard let path = Transcript.path(sessionId: session, cwd: cwd) else { return [] }
        var lines = parse(Tail.read(path: path, bytes: 512 * 1024))
        // One huge tool result can fill the whole tail; widen once when it comes up short.
        if lines.count < 4 { lines = parse(Tail.read(path: path, bytes: 4 * 1024 * 1024)) }
        return Array(lines.suffix(30))
    }

    static func parse(_ text: String) -> [ChatLine] {
        var out: [ChatLine] = []
        for line in text.split(whereSeparator: \.isNewline) {
            guard line.contains("\"user\"") || line.contains("\"assistant\""),
                  let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  obj["isMeta"] as? Bool != true, obj["isSidechain"] as? Bool != true,
                  let msg = obj["message"] as? [String: Any] else { continue }
            let blocks = (msg["content"] as? String).map { [["type": "text", "text": $0]] }
                ?? msg["content"] as? [[String: Any]] ?? []
            let mine = obj["type"] as? String == "user"
            for b in blocks {
                switch b["type"] as? String {
                case "text":
                    guard let t = (b["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !t.isEmpty, !t.hasPrefix("<"), !t.hasPrefix("[Request interrupted")
                    else { continue }
                    out.append(mine ? .you(t) : .claude(t))
                case "tool_use":
                    if case .tools(let n)? = out.last { out[out.count - 1] = .tools(n + 1) } else { out.append(.tools(1)) }
                default: continue
                }
            }
        }
        return out
    }
}

enum SwitcherCheck {
    static func run() -> Int32 {
        func row(_ name: String, _ cwd: String) -> AgentRow {
            AgentRow(agent: Agent(sessionId: name, name: name, cwd: cwd, state: nil, status: nil, pid: nil))
        }
        let rows = [row("fix login", "/r/mono"), row("add billing", "/r/web"), row("docs", "/r/mono")]
        let cases: [(String, [String])] = [
            ("", ["fix login", "add billing", "docs"]),
            ("MONO", ["fix login", "docs"]),
            ("mono log", ["fix login"]),
            ("web docs", []),
        ]
        var failed: Int32 = 0
        for (q, want) in cases + [("blue", [])] {
            let got = Switcher.filter(rows, q).map(\.agent.sessionId)
            if got != want {
                failed += 1
                FileHandle.standardError.write("FAIL filter(\(q)) = \(got), want \(want)\n".data(using: .utf8)!)
            }
        }
        // A colour tag is searchable by its name.
        for (q, want) in [("blue", ["docs"]), ("mono blue", ["docs"]), ("red", [])] {
            let got = Switcher.filter(rows, q, ["docs": 4]).map(\.agent.sessionId)
            if got != want {
                failed += 1
                FileHandle.standardError.write("FAIL filter(\(q)) = \(got), want \(want)\n".data(using: .utf8)!)
            }
        }
        let jsonl = """
        {"type":"user","message":{"role":"user","content":"fix the login"}}
        {"type":"user","isMeta":true,"message":{"role":"user","content":"meta"}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"On it"},{"type":"tool_use","id":"a","name":"Bash","input":{}}]}}
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"a","content":"ok"}]}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"b","name":"Read","input":{}}]}}
        {"type":"user","message":{"role":"user","content":[{"type":"text","text":"<system-reminder>x</system-reminder>"}]}}
        {"type":"assistant","isSidechain":true,"message":{"role":"assistant","content":[{"type":"text","text":"subagent"}]}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Done"}]}}
        """
        let chat = Chat.parse(jsonl)
        if chat != [.you("fix the login"), .claude("On it"), .tools(2), .claude("Done")] {
            failed += 1
            FileHandle.standardError.write("FAIL chat parse = \(chat)\n".data(using: .utf8)!)
        }
        if failed == 0 { print("switcher checks: ok") }
        return failed
    }
}
