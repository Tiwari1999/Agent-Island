import SwiftUI

/// A reader for one agent's recent output: what it said, and what it ran, in the order it
/// happened. Read-only by design — the notch does not pretend to be a terminal.
struct ConsoleView: View {
    @ObservedObject var store: AgentStore
    let session: String
    let onJump: () -> Void
    let onClose: () -> Void
    /// nil when the console was summoned by the chord rather than from the list.
    var onBack: (() -> Void)? = nil
    /// The panel refuses keyboard focus by default, so the island grants it for the field alone.
    var typingFor: String? = nil
    var onBeginType: (() -> Void)? = nil
    var onEndType: (() -> Void)? = nil

    @State private var feed: [ConsoleEntry] = []
    @State private var loaded = false
    @State private var draft = ""
    @State private var note: String?
    @FocusState private var writing: Bool
    /// Console.recent is mtime-cached, so re-reading an unchanged transcript costs a stat.
    private let tick = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    private var row: AgentRow? { store.rows.first { $0.agent.sessionId == session } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.hairline).frame(height: 0.7)
            body(for: feed)
            if let row, row.isWorking || row.waiting { live(row) }
            composer
        }
        .frame(width: Island.consoleSize.width, height: Island.consoleSize.height)
        .task(id: session) { await load() }
        // Without this the feed froze at open time while the footer kept animating.
        .onReceive(tick) { _ in Task { await load() } }
    }

    /// Answering from here is the point of reading here: the alternative is finding the tab.
    @ViewBuilder
    private var composer: some View {
        if let row {
            Rectangle().fill(Theme.hairline).frame(height: 0.7)
            HStack(spacing: 7) {
                if true {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold)).foregroundColor(Theme.working)
                    TextField(delivery(row).placeholder(row.displayName), text: $draft)
                        .textFieldStyle(.plain)
                        .font(Theme.mono(Type.small)).foregroundColor(Theme.text)
                        .focused($writing)
                        .onSubmit { send(to: row) }
                        .onTapGesture { onBeginType?(); writing = true }
                    if let note {
                        Text(note).font(Theme.mono(Type.micro)).foregroundColor(Theme.muted)
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .onChange(of: typingFor) { _, v in if v == nil { writing = false } }
        }
    }

    /// How this session can be reached. Warp publishes no scripting interface and macOS refuses
    /// TIOCSTI, so the only way in is Claude Code's own Stop hook — which needs a turn to end.
    private enum Delivery {
        case typed          // the terminal takes a line directly, idle or busy
        case queued         // no scripting interface, but a turn is running to hand it to
        case pasted         // no scripting interface and no turn: focus the tab, load the clipboard

        func placeholder(_ name: String) -> String {
            switch self {
            case .typed:  return "reply to \(name)"
            case .queued: return "steer \(name) — lands when it finishes"
            case .pasted: return "write to \(name) — opens Warp with it copied"
            }
        }
    }

    private func delivery(_ row: AgentRow) -> Delivery {
        if TerminalWrite.canWrite(row.host) { return .typed }
        // `waiting` counts too: a session parked on a question is mid-turn, so Stop is still coming.
        if row.agent.vendor == .claude, row.isWorking || row.waiting { return .queued }
        return .pasted
    }

    private func send(to row: AgentRow) {
        let line = draft
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let how = delivery(row)
        var ok: Bool
        switch how {
        case .typed:  ok = TerminalWrite.send(line, to: row.host)
        case .queued: ok = TerminalWrite.queue(line, session: row.agent.sessionId)
        case .pasted:
            // Nothing can put this line into an idle Warp tab, so put it one paste away and go
            // there. Two keystrokes beats retyping it, and it never lands in the wrong window.
            NSPasteboard.general.clearContents()
            ok = NSPasteboard.general.setString(line, forType: .string)
            if ok { onJump() }
        }
        note = ok ? (how == .typed ? "sent" : how == .queued ? "queued" : "copied — ⌘V there")
                  : "could not deliver"
        if ok { draft = "" }
        // Hand focus back, or the next keystroke anywhere lands in this field.
        onEndType?()
        writing = false
        Task { try? await Task.sleep(nanoseconds: 1_600_000_000); note = nil }
    }

    // MARK: - parts

    private var header: some View {
        HStack(spacing: 8) {
            if let onBack {
                tag("\u{2039} agents", action: onBack)
            }
            Circle()
                .fill(row?.waiting == true ? Theme.waiting
                      : row?.isWorking == true ? Theme.working : Theme.faint)
                .frame(width: 6, height: 6)
            if let p = row?.agent.cwd.map({ ($0 as NSString).lastPathComponent }) {
                Text(p).font(Theme.label(Type.title)).foregroundColor(Theme.text).lineLimit(1)
                Text("·").foregroundColor(Theme.faint)
            }
            Text(row?.displayName ?? "session")
                .font(Theme.mono(Type.body)).foregroundColor(Theme.muted).lineLimit(1)
            Spacer(minLength: 8)
            tag("open in terminal", action: onJump)
            tag("⌘⌥K", action: onClose)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    private func tag(_ t: String, action: @escaping () -> Void) -> some View {
        Text(t)
            .font(Theme.mono(Type.small)).foregroundColor(Theme.muted)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().stroke(Theme.hairline))
            .contentShape(Capsule())
            .onTapGesture(perform: action)
    }

    @ViewBuilder
    private func body(for feed: [ConsoleEntry]) -> some View {
        if !loaded {
            note("reading…")
        } else if feed.isEmpty {
            note("nothing recorded for this session yet")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(Console.group(feed)) { chunk(for: $0) }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, 15).padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // A console reads from the bottom: the newest line is the one you came for.
                // onAppear fires before the LazyVStack lays out, so the anchor is not yet
                // realised and the request is silently dropped.
                .onChange(of: feed.count) { _, _ in
                    DispatchQueue.main.async { proxy.scrollTo("end", anchor: .bottom) }
                }
                .onAppear {
                    DispatchQueue.main.async { proxy.scrollTo("end", anchor: .bottom) }
                }
            }
        }
    }

    private func note(_ t: String) -> some View {
        Text(t).font(Theme.mono(Type.body)).foregroundColor(Theme.faint)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Prose is what you came to read; the tools it ran are quiet annotations beside it.
    @ViewBuilder
    private func chunk(for c: ConsoleChunk) -> some View {
        switch c.kind {
        case .said(let text, let at):
            VStack(alignment: .leading, spacing: 5) {
                if let at { stamp(at) }
                MarkdownLite(text: text, style: .reading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .ran(let items):
            HStack(alignment: .top, spacing: 9) {
                Rectangle().fill(Theme.hairline).frame(width: 1.5)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(items) { ran($0) }
                }
            }
            .padding(.leading, 2)
        }
    }

    private func stamp(_ at: Date) -> some View {
        Text(Self.clock.string(from: at))
            .font(Theme.mono(Type.micro)).foregroundColor(Theme.faint.opacity(0.65))
    }

    @ViewBuilder
    private func ran(_ e: ConsoleEntry) -> some View {
        if case let .ran(tool, why, cmd, seconds, failed) = e.kind {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(tool)
                    .font(Theme.mono(Type.small))
                    .foregroundColor(failed ? Theme.failed : Theme.muted)
                    .frame(width: 56, alignment: .leading)
                // What was sent leads the line; the agent's reason trails it, quieter.
                Text(cmd ?? why)
                    .font(Theme.mono(Type.small))
                    .foregroundColor(failed ? Theme.failed : Theme.text)
                    .lineLimit(1).truncationMode(.middle)
                    .layoutPriority(1)
                if let cmd, !why.isEmpty, why != cmd {
                    Text(why)
                        .font(Theme.mono(Type.small)).foregroundColor(Theme.faint)
                        .lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 4)
                if let s = seconds, s >= 0.5 {
                    Text(s < 60 ? String(format: "%.0fs", s)
                                : String(format: "%.0fm", (s / 60).rounded()))
                        .font(Theme.mono(Type.micro)).foregroundColor(Theme.faint.opacity(0.7))
                }
            }
        }
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()

    private func live(_ row: AgentRow) -> some View {
        HStack(spacing: 7) {
            Circle().fill(row.waiting ? Theme.waiting : Theme.working).frame(width: 5, height: 5)
            Text(row.waiting ? "waiting for you" : (row.activity ?? "working"))
                .font(Theme.mono(Type.small))
                .foregroundColor(row.waiting ? Theme.waiting : Theme.working)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Theme.raised)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 0.7) }
    }

    /// Parsing a transcript tail is measured in tens of milliseconds, which is long enough to
    /// drop a frame — so it never happens on the main actor.
    private func load() async {
        let id = session, cwd = row?.agent.cwd
        let parsed: [ConsoleEntry] = await withCheckedContinuation { k in
            DispatchQueue.global(qos: .userInitiated).async {
                k.resume(returning: Console.recent(session: id, cwd: cwd))
            }
        }
        // `session` is a let on the captured view value, so comparing it to itself was a
        // compile-time true. .task(id:) cancels the previous run, which this can actually see.
        guard !Task.isCancelled else { return }
        feed = parsed
        loaded = true
    }
}
