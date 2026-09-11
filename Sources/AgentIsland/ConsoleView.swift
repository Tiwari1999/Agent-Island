import SwiftUI

/// A reader for one agent's recent output: what it said, and what it ran, in the order it
/// happened. Read-only by design — the notch does not pretend to be a terminal.
struct ConsoleView: View {
    @ObservedObject var store: AgentStore
    let session: String
    let onJump: () -> Void
    let onClose: () -> Void

    @State private var feed: [ConsoleEntry] = []
    @State private var loaded = false
    /// Console.recent is mtime-cached, so re-reading an unchanged transcript costs a stat.
    private let tick = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    private var row: AgentRow? { store.rows.first { $0.agent.sessionId == session } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.hairline).frame(height: 0.7)
            body(for: feed)
            if let row, row.isWorking || row.waiting { live(row) }
        }
        .frame(width: Island.consoleSize.width, height: Island.consoleSize.height)
        .task(id: session) { await load() }
        // Without this the feed froze at open time while the footer kept animating.
        .onReceive(tick) { _ in Task { await load() } }
    }

    // MARK: - parts

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(row?.waiting == true ? Theme.waiting
                      : row?.isWorking == true ? Theme.working : Theme.faint)
                .frame(width: 6, height: 6)
            if let p = row?.agent.cwd.map({ ($0 as NSString).lastPathComponent }) {
                Text(p).font(Theme.label(11)).foregroundColor(Theme.text).lineLimit(1)
                Text("·").foregroundColor(Theme.faint)
            }
            Text(row?.displayName ?? "session")
                .font(Theme.mono(10)).foregroundColor(Theme.muted).lineLimit(1)
            Spacer(minLength: 8)
            tag("open in terminal", action: onJump)
            tag("⌘⌥K", action: onClose)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    private func tag(_ t: String, action: @escaping () -> Void) -> some View {
        Text(t)
            .font(Theme.mono(9)).foregroundColor(Theme.muted)
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
        Text(t).font(Theme.mono(10)).foregroundColor(Theme.faint)
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
            .font(Theme.mono(8.5)).foregroundColor(Theme.faint.opacity(0.65))
    }

    @ViewBuilder
    private func ran(_ e: ConsoleEntry) -> some View {
        if case let .ran(tool, why, seconds, failed) = e.kind {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(tool)
                    .font(Theme.mono(9))
                    .foregroundColor(failed ? Theme.failed : Theme.muted)
                    .frame(width: 56, alignment: .leading)
                Text(why)
                    .font(Theme.mono(9)).foregroundColor(Theme.faint)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if let s = seconds, s >= 0.5 {
                    Text(s < 60 ? String(format: "%.0fs", s)
                                : String(format: "%.0fm", (s / 60).rounded()))
                        .font(Theme.mono(8.5)).foregroundColor(Theme.faint.opacity(0.7))
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
                .font(Theme.mono(9.5))
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
