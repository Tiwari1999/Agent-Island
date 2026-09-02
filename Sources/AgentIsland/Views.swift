import SwiftUI

/// Resting state: hugs the notch. Stays visible whenever anything is live, because a status
/// surface you must hover to discover is not a status surface.
struct CollapsedView: View {
    @ObservedObject var store: AgentStore
    @ObservedObject var status: StatusStore
    let notchWidth: CGFloat
    /// True while the pointer is on the notch. At rest the bar stays narrow so the menu bar
    /// beside the notch keeps working; pointing at it widens the bar to show what is running.
    var revealed: Bool = false

    /// Content is never allowed nearer the notch than this — text sliding under the camera
    /// housing is the one thing that makes the bar look broken.
    static let notchMargin: CGFloat = 14
    /// Live agent activity stays visible at rest — that ambient view is the point of the bar,
    /// and hiding it behind a hover made the island useless at a glance.
    static let sideWidth: CGFloat = 148

    static func side(revealed: Bool) -> CGFloat { sideWidth }

    private var lead: AgentRow? {
        store.rows.first { $0.waiting } ?? store.rows.first { $0.agent.isWorking }
    }

    var body: some View {
        HStack(spacing: 0) {
            // LEFT — who and what, hard-capped so it cannot reach the notch.
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                if let row = lead {
                    AgentAvatar(seed: row.agent.sessionId, size: 13, active: true)
                    Text(row.activity ?? row.displayName)
                        .font(Theme.mono(9.5))
                        .foregroundColor(row.waiting ? Theme.waiting : Theme.muted)
                        .lineLimit(1).truncationMode(.tail)
                } else {
                    Text("idle").font(Theme.mono(9.5)).foregroundColor(Theme.faint)
                }
            }
            .frame(width: Self.side(revealed: revealed), alignment: .trailing)
            .padding(.trailing, Self.notchMargin)
            .clipped()

            Spacer().frame(width: notchWidth)

            // RIGHT — counts and quota pressure, at a glance.
            HStack(spacing: 7) {
                if store.workingCount > 0 {
                    HStack(spacing: 4) {
                        // Static on purpose: this bar is visible all day, and a permanently
                        // animating element is both a battery cost and, per the motion budget,
                        // noise rather than signal. Motion is reserved for "needs you".
                        Circle().fill(Theme.working).frame(width: 6, height: 6)
                        Text("\(store.workingCount)")
                            .font(Theme.label(9.5)).foregroundColor(Theme.working)
                            .contentTransition(.numericText(value: Double(store.workingCount)))
                            .animation(.snappy(duration: 0.25), value: store.workingCount)
                    }
                }
                if store.blockedCount > 0 && store.waitingCount == 0 {
                    Text("\(store.blockedCount)")
                        .font(Theme.mono(9)).foregroundColor(Theme.faint)
                }
                if store.waitingCount > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "bell.fill")
                            .font(.system(size: 7.5)).foregroundColor(Theme.waiting)
                            .symbolEffect(.bounce, value: store.waitingCount)
                        Text("\(store.waitingCount)")
                            .font(Theme.label(9.5)).foregroundColor(Theme.waiting)
                            .contentTransition(.numericText(value: Double(store.waitingCount)))
                            .animation(.snappy(duration: 0.25), value: store.waitingCount)
                    }
                }
                if let pct = status.quota.fiveHourPct {
                    Text("\(pct)%")
                        .font(Theme.mono(9)).foregroundColor(Quota.tint(pct))
                        .contentTransition(.numericText(value: Double(pct)))
                        .animation(.snappy(duration: 0.3), value: pct)
                }
                Spacer(minLength: 0)
            }
            .frame(width: Self.side(revealed: revealed), alignment: .leading)
            .padding(.leading, Self.notchMargin)
            .clipped()
        }
    }
}

/// Dynamic-Island-style announcement: drops below the notch, holds, springs away.
struct PeekView: View {
    let title: String
    let message: String
    let needsInput: Bool
    let notchWidth: CGFloat

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill((needsInput ? Theme.waiting : Theme.working).opacity(0.16))
                    .frame(width: 26, height: 26)
                Image(systemName: needsInput ? "hand.raised.fill" : "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .contentTransition(.symbolEffect(.replace.downUp))
                    .foregroundColor(needsInput ? Theme.waiting : Theme.working)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Theme.label(11.5)).foregroundColor(Theme.text)
                    .lineLimit(1).truncationMode(.tail)
                Text(message).font(Theme.mono(9.5)).foregroundColor(Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text("jump").font(Theme.mono(9)).foregroundColor(Theme.faint)
            Image(systemName: "arrow.up.forward").font(.system(size: 9)).foregroundColor(Theme.faint)
        }
        .padding(.horizontal, 14)
    }
}

struct AgentRowView: View {
    static let height: CGFloat = 64

    let row: AgentRow
    let model: String?
    var onPlan: (() -> Void)? = nil
    let onJump: () -> Void
    @State private var hover = false

    private var tint: Color {
        if row.waiting { return Theme.waiting }
        if row.agent.isWorking { return Theme.working }
        if row.agent.phase == "failed" { return Theme.failed }
        if row.dormantBlocked { return Theme.muted }
        return Theme.idle
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 5) {
                AgentAvatar(seed: row.agent.sessionId, size: 20,
                            active: row.agent.isWorking || row.waiting)
                if row.agent.isWorking { ActivityBars(color: tint, height: 9, active: true) }
                else { Dot(color: tint, size: 5, pulse: row.waiting) }
            }
            .frame(width: 22)
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    // project · title, the way the reference reads: context then subject.
                    Text(row.agent.project).font(Theme.label(12)).foregroundColor(Theme.text)
                    Text("·").foregroundColor(Theme.faint)
                    Text(row.displayName)
                        .font(Theme.label(12)).foregroundColor(Theme.text)
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 6)
                    if let host = row.agent.remoteHost {
                        // The short name is what a human calls the box; the full alias is noise.
                        chip("⇅ " + (host.split(separator: ".").first.map(String.init) ?? host),
                             Theme.amber)
                    }
                    chip(row.agent.vendor.label, Theme.agentTint)
                    if let m = model { chip(m, Theme.muted) }
                    chip(row.terminal, row.precise ? Theme.muted : Theme.faint)
                    if let onPlan {
                        HStack(spacing: 3) {
                            Image(systemName: "doc.plaintext").font(.system(size: 8))
                            Text("plan").font(Theme.mono(8.5))
                        }
                        .foregroundColor(Theme.working)
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(Capsule().fill(Theme.working.opacity(0.12)))
                        .contentShape(Capsule())
                        .onTapGesture(perform: onPlan)
                    }
                    if let t = row.tasks {
                        HStack(spacing: 3) {
                            Image(systemName: t.blocked ? "exclamationmark.circle" : "checklist")
                                .font(.system(size: 8))
                            Text(t.label).font(Theme.mono(8.5))
                        }
                        .foregroundColor(t.blocked ? Theme.failed : Theme.muted)
                    }
                    if let c = row.contextPct, c >= 60 {
                        // Context pressure only earns space once it is worth acting on.
                        HStack(spacing: 3) {
                            ContextRing(pct: c)
                            Text("\(c)%").font(Theme.mono(8.5))
                        }
                        .foregroundColor(c >= 90 ? Theme.failed : c >= 75 ? Theme.amber : Theme.muted)
                    }
                    Text(row.ago).font(Theme.mono(9)).foregroundColor(Theme.faint)
                    Image(systemName: row.isBackground
                          ? "arrow.down.right.and.arrow.up.left.circle" : "arrow.up.forward.app.fill")
                        .font(.system(size: 10.5)).foregroundColor(hover ? tint : Theme.faint)
                }

                if let p = row.lastPrompt, !p.isEmpty {
                    Text("You: \(p)")
                        .font(Theme.mono(9.5)).foregroundColor(Theme.muted)
                        .lineLimit(1).truncationMode(.tail)
                }

                // Tool name reads as a link, argument stays quiet — the reference's "Bash cargo test".
                HStack(spacing: 5) {
                    if let why = row.died {
                        Image(systemName: "xmark.octagon.fill")
                            .font(.system(size: 8)).foregroundColor(Theme.failed)
                        Text("died · \(why)").font(Theme.mono(9.5)).foregroundColor(Theme.failed)
                    } else if let t = row.tool {
                        Text(t).font(Theme.mono(9.5)).foregroundColor(Theme.tool)
                    }
                    if row.dormantBlocked, let q = row.blockedQuestion {
                        Image(systemName: "pause.circle")
                            .font(.system(size: 8)).foregroundColor(Theme.faint)
                        Text("blocked · \(q)")
                            .font(Theme.mono(9.5)).foregroundColor(Theme.muted)
                            .lineLimit(1).truncationMode(.tail)
                    } else if row.died == nil {
                        Text(row.tasks?.current
                             ?? row.activity
                             ?? (row.waiting ? "waiting for your input" : row.agent.phase))
                            .font(Theme.mono(9.5))
                            .foregroundColor(row.waiting ? Theme.waiting : Theme.faint)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        // Rows are a fixed height so the panel can size itself exactly; centring splits the
        // slack of a two-line row instead of pooling it all under the text as a gap.
        .frame(height: AgentRowView.height, alignment: .center)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(hover && row.canJump ? Theme.raised : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .onTapGesture { if row.canJump { onJump() } }
        .help(row.isBackground ? "Background session — opens a tab, attach command copied"
              : row.precise ? "Jump to this session in \(row.terminal)"
              : "Raise \(row.terminal) — it exposes no per-tab focus API")
    }

    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(Theme.mono(8.5)).foregroundColor(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.13)))
            .lineLimit(1)
    }
}

struct PanelView: View {
    static let width: CGFloat = 640
    static let visibleRows: CGFloat = 3
    static let headerHeight: CGFloat = 40
    static let rowGap: CGFloat = 5
    /// Height of the scrolling area: exactly N rows and the gaps between them, nothing partial.
    static let listPadding: CGFloat = 8
    /// Must match the stack's padding exactly, or the last row is clipped by the difference and
    /// the list scrolls by a sliver that reads as a partial row.
    static var listHeight: CGFloat {
        visibleRows * AgentRowView.height + (visibleRows - 1) * rowGap + 2 * listPadding
    }
    static var height: CGFloat { headerHeight + 1 + listHeight }
    @ObservedObject var store: AgentStore
    @ObservedObject var status: StatusStore
    @State private var mode: PanelMode = .sessions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "bolt.horizontal.fill")
                    .font(.system(size: 9)).foregroundColor(Theme.agentTint)
                window("5h", status.quota.fiveHourPct, status.quota.fiveHourResets)
                if let r = status.quota.burnPerHour, r >= 0.5 {
                    HStack(spacing: 3) {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 8)).foregroundColor(burnTint)
                        Text(Quota.rate(r)).font(Theme.mono(9)).foregroundColor(burnTint)
                        if let e = status.quota.exhaustsIn, e < 6 * 3600 {
                            Text("· full in \(Quota.short(e))")
                                .font(Theme.mono(9)).foregroundColor(Theme.faint)
                        }
                    }
                }
                Text("|").font(Theme.mono(9)).foregroundColor(Theme.hairline)
                window("7d", status.quota.sevenDayPct, status.quota.sevenDayResets)
                Spacer()
                costChip
                if store.workingCount > 0 { pill("\(store.workingCount) working", Theme.working) }
                if store.waitingCount > 0 { pill("\(store.waitingCount) waiting", Theme.waiting) }
                if store.blockedCount > 0 { pill("\(store.blockedCount) blocked", Theme.faint) }
                Text("\(store.rows.count)").font(Theme.mono(9.5)).foregroundColor(Theme.faint)
            }
            .padding(.horizontal, 14)
            .frame(height: PanelView.headerHeight)

            Rectangle().fill(Theme.hairline).frame(height: 0.7)

            if case .costs = mode {
                CostsView(table: store.costTable) { back() }
                    .frame(height: PanelView.listHeight)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            } else if case .plan(let session, let title) = mode {
                PlanReader(title: title,
                           markdown: store.hooks.plans[session]?.markdown ?? "plan no longer available") {
                    back()
                }
                .frame(height: PanelView.listHeight)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            } else if store.rows.isEmpty {
                VStack(spacing: 5) {
                    // An app that has never refreshed and one with nothing to show used to look
                    // identical, which is how a silent failure reads as an empty desk.
                    Text(store.hasRefreshed ? "No sessions" : "Looking for agents…")
                        .font(Theme.name(12)).foregroundColor(Theme.muted)
                    Text(store.hasRefreshed
                         ? "start one with `claude`, `codex` or `cursor-agent`"
                         : "reading Claude Code, Codex and Cursor")
                        .font(Theme.mono(9.5)).foregroundColor(Theme.faint)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: PanelView.rowGap) {
                        ForEach(store.rows) { row in
                            AgentRowView(row: row, model: status.quota.model,
                                         onPlan: store.hooks.plans[row.agent.sessionId].map { _ in
                                             { withAnimation(.spring(response: 0.30, dampingFraction: 0.85)) {
                                                   mode = .plan(session: row.agent.sessionId,
                                                                title: row.displayName)
                                               } }
                                         }) { store.jump(row) }
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, PanelView.listPadding)
                }
                .frame(height: PanelView.listHeight)
                .scrollIndicators(.never)
                .clipped()
            }
        }
        .frame(width: PanelView.width, height: PanelView.height)
    }

    /// Burn is only alarming when it would exhaust the window before it resets.
    private var burnTint: Color {
        guard let e = status.quota.exhaustsIn,
              let resets = status.quota.fiveHourResets else { return Theme.muted }
        return e < resets.timeIntervalSinceNow ? Theme.failed : Theme.muted
    }

    /// "5h 23% 4h36m" — label, pressure, and when it clears.
    private func window(_ label: String, _ pct: Int?, _ resets: Date?) -> some View {
        HStack(spacing: 4) {
            Text(label).font(Theme.label(10)).foregroundColor(Theme.text)
            Text(pct.map { "\($0)%" } ?? "—")
                .font(Theme.label(10)).foregroundColor(Quota.tint(pct))
            Text(Quota.remaining(resets)).font(Theme.mono(9)).foregroundColor(Theme.faint)
        }
    }

    private func back() {
        withAnimation(.spring(response: 0.30, dampingFraction: 0.85)) { mode = .sessions }
    }

    private var costChip: some View {
        let today = Costs.today(store.costTable).values.reduce(0) { $0 + $1.cost }
        return HStack(spacing: 3) {
            Image(systemName: "dollarsign.circle").font(.system(size: 8.5))
            Text(store.costTable.isEmpty ? "cost" : Costs.dollars(today))
                .font(Theme.mono(9.5))
        }
        .foregroundColor(Theme.muted)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(Theme.raised))
        .contentShape(Capsule())
        .onTapGesture {
            withAnimation(.spring(response: 0.30, dampingFraction: 0.85)) {
                if case .costs = mode { mode = .sessions } else { mode = .costs }
            }
            if case .costs = mode { store.refreshCosts() }
        }
    }

    private func pill(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(Theme.label(9)).foregroundColor(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}


/// A blocked tool call, answerable without leaving the notch.
struct ApprovalCard: View {
    let approval: Approval
    let agentName: String
    var context: ApprovalContext? = nil
    var onExpand: (() -> Void)? = nil
    let onAllow: () -> Void
    let onDeny: () -> Void
    @State private var hoverAllow = false
    @State private var hoverDeny = false

    var body: some View {
        VStack(spacing: 0) {
            header
            // A plan is reviewed where it is approved — switching to the terminal to read it
            // defeats the point of answering from the notch.
            if let plan = approval.plan {
                Rectangle().fill(Theme.hairline).frame(height: 0.7).padding(.top, 8)
                ScrollView {
                    MarkdownLite(text: plan)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if let ctx = context {
                Rectangle().fill(Theme.hairline).frame(height: 0.7).padding(.top, 8)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if !ctx.risks.isEmpty {
                            HStack(spacing: 5) {
                                ForEach(ctx.risks, id: \.self) { r in
                                    Text(r).font(Theme.mono(8.5))
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Capsule().fill(Theme.failed.opacity(0.14)))
                                        .foregroundColor(Theme.failed)
                                }
                            }
                        }
                        if let why = ctx.why {
                            section("WHY — the agent's last words") {
                                MarkdownLite(text: String(why.suffix(900)))
                            }
                        }
                        if let full = approval.fullInput {
                            section("THE FULL ASK") {
                                Text(full).font(Theme.mono(9.5)).foregroundColor(Theme.muted)
                                    .textSelection(.enabled)
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.raised))
                            }
                        }
                        if !ctx.trail.isEmpty {
                            section("RECENT ACTIVITY") {
                                VStack(alignment: .leading, spacing: 3) {
                                    ForEach(Array(ctx.trail.enumerated()), id: \.offset) { _, t in
                                        Text(t).font(Theme.mono(9)).foregroundColor(Theme.faint)
                                            .lineLimit(1).truncationMode(.middle)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder private func section(_ title: String,
                                      @ViewBuilder _ body: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Theme.mono(8.5)).foregroundColor(Theme.faint).kerning(0.8)
            body()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Theme.waiting.opacity(0.16)).frame(width: 30, height: 30)
                Image(systemName: approval.plan != nil ? "doc.plaintext.fill" : "hand.raised.fill")
                    .font(.system(size: 12, weight: .bold)).foregroundColor(Theme.waiting)
                    .symbolEffect(.pulse, options: .repeating)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(agentName).font(Theme.label(11.5)).foregroundColor(Theme.text).lineLimit(1)
                    Text(approval.tool)
                        .font(Theme.mono(8.5)).foregroundColor(Theme.waiting)
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(Capsule().fill(Theme.waiting.opacity(0.14)))
                }
                Text(approval.detail)
                    .font(Theme.mono(9.5)).foregroundColor(Theme.muted)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if approval.plan == nil, context == nil, let onExpand {
                Text("context ⌘⌥E")
                    .font(Theme.label(10.5)).foregroundColor(Theme.muted)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.raised))
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onExpand)
            }
            button("Deny ⌘⌥D", Theme.failed, hoverDeny, onDeny) { hoverDeny = $0 }
            button(approval.plan != nil ? "Approve plan ⌘⌥A" : "Allow ⌘⌥A",
                   Theme.working, hoverAllow, onAllow) { hoverAllow = $0 }
        }
        .padding(.horizontal, 14)
    }

    private func button(_ title: String, _ tint: Color, _ hot: Bool,
                        _ act: @escaping () -> Void,
                        _ hover: @escaping (Bool) -> Void) -> some View {
        Text(title)
            .font(Theme.label(10.5))
            .foregroundColor(hot ? Theme.bg : tint)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(hot ? tint : tint.opacity(0.14)))
            .contentShape(Rectangle())
            .onHover { h in withAnimation(.easeOut(duration: 0.1)) { hover(h) } }
            .onTapGesture(perform: act)
    }
}

/// A blocked question, answerable in one click.
struct QuestionCard: View {
    let question: Question
    let agentName: String
    let onChoose: (String) -> Void
    @State private var hot: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(Theme.waiting.opacity(0.16)).frame(width: 24, height: 24)
                    Image(systemName: "questionmark")
                        .font(.system(size: 11, weight: .bold)).foregroundColor(Theme.waiting)
                }
                Text(agentName).font(Theme.label(11)).foregroundColor(Theme.muted).lineLimit(1)
                if !question.header.isEmpty {
                    Text(question.header)
                        .font(Theme.mono(8.5)).foregroundColor(Theme.waiting)
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(Capsule().fill(Theme.waiting.opacity(0.14)))
                }
                Spacer(minLength: 0)
            }
            Text(question.text)
                .font(Theme.name(12.5)).foregroundColor(Theme.text)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)

            // Numbered so the choice is scannable, and wrapped so long labels stay readable.
            HStack(spacing: 6) {
                ForEach(Array(question.options.prefix(4).enumerated()), id: \.offset) { i, opt in
                    let on = hot == opt
                    HStack(spacing: 5) {
                        Text("⌘⌥\(i + 1)").font(Theme.mono(8))
                            .foregroundColor(on ? Theme.bg.opacity(0.7) : Theme.faint)
                        Text(opt).font(Theme.label(10.5)).lineLimit(1)
                            .foregroundColor(on ? Theme.bg : Theme.text)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 7)
                        .fill(on ? Theme.waiting : Theme.waiting.opacity(0.12)))
                    .contentShape(Rectangle())
                    .onHover { h in withAnimation(.easeOut(duration: 0.1)) { hot = h ? opt : nil } }
                    .onTapGesture { onChoose(opt) }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}


/// A tiny dial for context pressure — shape carries the reading before the number does.
struct ContextRing: View {
    let pct: Int
    var size: CGFloat = 9

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.12), lineWidth: 1.6)
            Circle()
                .trim(from: 0, to: min(1, Double(pct) / 100))
                .stroke(pct >= 90 ? Theme.failed : pct >= 75 ? Theme.amber : Theme.muted,
                        style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
    }
}
