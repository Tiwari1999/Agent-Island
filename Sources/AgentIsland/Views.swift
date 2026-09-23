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
    /// Nothing running, nothing waiting, pointer elsewhere: say the least the bar can say.
    var quiet: Bool = false

    /// Content is never allowed nearer the notch than this — text sliding under the camera
    /// housing is the one thing that makes the bar look broken.
    static let notchMargin: CGFloat = 14
    /// Live agent activity stays visible at rest — that ambient view is the point of the bar,
    /// and hiding it behind a hover made the island useless at a glance.

    /// The two sides are not equal: the right holds three short numbers, the left holds a
    /// sentence. Splitting the same total 210/86 instead of 148/148 buys the sentence room
    /// without the bar growing at all; hover buys it more.
    /// Sized to what there is to say. A fixed 210 left a wide empty gap whenever the activity
    /// line was short, which reads as a bar that is mostly nothing.
    /// Each side is sized to what it holds — a sentence on the left, numbers on the right — and
    /// never mirrored. Forcing both to the wider one squared the sentence's width onto a side
    /// that only ever prints two percentages, and the bar grew half a screen wide for nothing.
    /// The notch gap stays put through `Island.shellOffsetX`, not through symmetry.
    /// 6.2/char is the measured advance of the real 10pt monospace face; the old 5.3 was tuned
    /// for an 8.5pt scale that no longer exists, so every line silently overran its box.
    static func sides(revealed: Bool, left leftText: String? = nil,
                      right rightText: String? = nil) -> (left: CGFloat, right: CGFloat) {
        // pulse + avatar + gaps on the left; the counts render a point larger on the right.
        let l = max(112, min(revealed ? 300 : 220, 46 + CGFloat(min((leftText ?? "").count, 30)) * 6.0))
        let r = max(86, min(310, 34 + CGFloat((rightText ?? "").count) * 6.9))
        return (l, r)
    }

    /// What the bar is actually going to print, which is what its width should follow.
    var leadText: String? { lead.map { $0.activity ?? $0.displayName } }

    /// The left side: what is happening, or — when nothing is — what today has cost. The limits
    /// that used to sit opposite are in the panel's footer now; the bar keeps only what changes
    /// second to second, which is what a glance at a notch is for.
    var leftText: String? { leadText ?? spentText }

    /// Today's spend, worded so it cannot be mistaken for a remaining budget.
    var spentText: String? { usageToday.map { "spent \($0)" } }

    /// The counts, each with the noun it counts. A bare "1" beside a percentage read as one more
    /// unlabelled number; nothing said whether it was agents, minutes or a rank.
    var countsText: String? {
        guard !quiet else { return nil }
        var parts: [String] = []
        // One working agent is already said by the pulse and the row beside it; printing "1
        // working" next to two percentages only added a number to read and width to pay for.
        if store.workingCount > 1 { parts.append("\(store.workingCount) working") }
        if store.waitingCount > 0 { parts.append("\(store.waitingCount) waiting") }
        else if store.blockedCount > 0 { parts.append("\(store.blockedCount) blocked") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Everything the right side prints, so its width follows the whole line and not one part.
    /// The limits are NOT here: they cost more width on the bar than they were worth and now
    /// live along the panel's footer, where there is room for their reset times too.
    var rightText: String? { countsText }

    /// Spend and tokens for the agent the panel is reporting on, today.
    private var usageToday: String? {
        let today = Costs.today(store.costTable)
        guard !today.isEmpty else { return nil }
        let v = store.effectiveVendor
        let spend = Costs.spend(today, for: v)
        let toks = Costs.tokens(today, for: v)
        guard toks > 0 else { return nil }
        return "\(Costs.dollars(spend)) · \(Costs.tokens(toks))"
    }

    private var lead: AgentRow? {
        store.rows.first { $0.waiting } ?? store.rows.first { $0.isWorking }
    }

    var body: some View {
        HStack(spacing: 0) {
            // LEFT — who and what, hard-capped so it cannot reach the notch.
            HStack(spacing: 6) {
                // Leading edge, ahead of the Spacer: this group is trailing-aligned and clipped,
                // so anything placed after a greedy Text is the first thing cut off.
                if !quiet, let row = lead, row.workKind != .idle {
                    // Kept off the rounded corner, which was clipping it.
                    RunningPulse(kind: row.workKind).padding(.leading, 4)
                }
                Spacer(minLength: 0)
                if let row = lead {
                    AgentAvatar(seed: row.agent.sessionId, size: 13, active: true)
                    Text(row.activity ?? row.displayName)
                        .font(Theme.mono(Type.small))
                        .foregroundColor(row.waiting ? Theme.waiting : Theme.muted)
                        .lineLimit(1).truncationMode(.tail)
                        // Bounded so the text cannot grow into the pulse's place.
                        .frame(maxWidth: Self.sides(revealed: revealed, left: leftText,
                                                    right: rightText).left - 46,
                               alignment: .trailing)
                } else if let s = spentText {
                    // Nothing running: the left carries what today cost, so the bar stays balanced
                    // and the two sides read as one sentence — spent here, left there.
                    Text(s).font(Theme.mono(Type.micro)).foregroundColor(Theme.faint).lineLimit(1)
                } else {
                    Text("idle").font(Theme.mono(Type.small)).foregroundColor(Theme.faint)
                }
            }
            .frame(width: Self.sides(revealed: revealed, left: leftText, right: rightText).left,
                   alignment: .trailing)
            .padding(.trailing, Self.notchMargin)
            .clipped()

            Spacer().frame(width: notchWidth)

            // RIGHT — counts and quota pressure, at a glance.
            HStack(spacing: 7) {
                if store.workingCount > 1 {
                    HStack(spacing: 3) {
                        Text("\(store.workingCount)")
                            .font(Theme.label(Type.small)).foregroundColor(Theme.working)
                            .contentTransition(.numericText(value: Double(store.workingCount)))
                            .animation(Motion.value, value: store.workingCount)
                        Text("working").font(Theme.mono(Type.micro))
                            .foregroundColor(Theme.working.opacity(0.85))
                    }
                    .lineLimit(1)
                }
                if store.waitingCount > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "bell.fill")
                            .font(.system(size: 9)).foregroundColor(Theme.waiting)
                            .symbolEffect(.bounce, value: store.waitingCount)
                        Text("\(store.waitingCount)")
                            .font(Theme.label(Type.small)).foregroundColor(Theme.waiting)
                            .contentTransition(.numericText(value: Double(store.waitingCount)))
                            .animation(Motion.value, value: store.waitingCount)
                        Text("waiting").font(Theme.mono(Type.micro)).foregroundColor(Theme.waiting)
                    }
                    .lineLimit(1)
                } else if store.blockedCount > 0 {
                    HStack(spacing: 3) {
                        Text("\(store.blockedCount)")
                            .font(Theme.mono(Type.small)).foregroundColor(Theme.faint)
                        Text("blocked").font(Theme.mono(Type.micro)).foregroundColor(Theme.faint)
                    }
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(width: Self.sides(revealed: revealed, left: leftText, right: rightText).right,
                   alignment: .leading)
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
                Text(title).font(Theme.label(Type.title)).foregroundColor(Theme.text)
                    .lineLimit(1).truncationMode(.tail)
                Text(message).font(Theme.mono(Type.small)).foregroundColor(Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text("jump").font(Theme.mono(Type.small)).foregroundColor(Theme.faint)
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
    /// Present when this row has a question still waiting. A card that timed out is otherwise
    /// unreachable: the user has no way of knowing the row will bring it back.
    var onAnswer: (() -> Void)? = nil
    /// Read this session's recent output without leaving the notch. The row's own chevron
    /// opens it — the console shows every call with what was sent, so nothing needs two doors.
    var onConsole: (() -> Void)? = nil
    let onJump: () -> Void
    @State private var hover = false

    /// "Claude · Fable 5 · Warp", with a ⇅ host prefix when the session is remote.
    private var identity: String {
        var parts: [String] = []
        if let host = row.agent.remoteHost {
            parts.append("⇅ " + (host.split(separator: ".").first.map(String.init) ?? host))
        }
        parts.append(row.agent.vendor.label)
        if let m = model, row.agent.vendor == .claude { parts.append(m) }
        parts.append(row.terminal)
        return parts.joined(separator: " · ")
    }

    /// What the agent has actually been doing, newest first. The intent is the headline and
    /// the output is evidence — leading with commands would be unreadable, since most of them
    /// are shell noise and a good share of the output is minified source.


    private var tint: Color {
        if row.waiting { return Theme.waiting }
        if row.isWorking { return Theme.working }
        if row.agent.phase == "failed" { return Theme.failed }
        if row.dormantBlocked { return Theme.muted }
        return Theme.idle
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 5) {
                AgentAvatar(seed: row.agent.sessionId, size: 20,
                            active: row.isWorking || row.waiting)
                if row.isWorking { ActivityBars(color: tint, height: 9, active: true) }
                else { Dot(color: tint, size: 5, pulse: row.waiting) }
            }
            .frame(width: 22)
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if let onConsole {
                        // Its own hit target: clicking the row still jumps, exactly as before.
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Theme.faint)
                            .frame(width: 11, height: 14)
                            .contentShape(Rectangle())
                            .onTapGesture(perform: onConsole)
                    }
                    // project · title, the way the reference reads: context then subject.
                    Text(row.agent.project).font(Theme.label(Type.title)).foregroundColor(Theme.text)
                    Text("·").foregroundColor(Theme.faint)
                    Text(row.displayName)
                        .font(Theme.label(Type.title)).foregroundColor(Theme.text)
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 6)
                    // One quiet identity cluster instead of three capsules: what a row IS
                    // never demands action, so it never earns three separate shapes.
                    chip(identity, row.agent.remoteHost != nil ? Theme.amber : Theme.muted)
                    if let onAnswer {
                        HStack(spacing: 3) {
                            Image(systemName: "questionmark.bubble.fill").font(.system(size: 10))
                            Text("answer").font(Theme.mono(Type.micro))
                        }
                        .foregroundColor(Theme.waiting)
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(Capsule().fill(Theme.waiting.opacity(0.14)))
                        .contentShape(Capsule())
                        .onTapGesture(perform: onAnswer)
                    }
                    if let onPlan {
                        HStack(spacing: 3) {
                            Image(systemName: "doc.plaintext").font(.system(size: 10))
                            Text("plan").font(Theme.mono(Type.micro))
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
                                .font(.system(size: 10))
                            Text(t.label).font(Theme.mono(Type.micro))
                        }
                        .foregroundColor(t.blocked ? Theme.failed : Theme.muted)
                    }
                    if let c = row.contextPct, c >= 60 {
                        // Context pressure only earns space once it is worth acting on.
                        HStack(spacing: 3) {
                            ContextRing(pct: c)
                            Text("\(c)%").font(Theme.mono(Type.micro))
                        }
                        .foregroundColor(c >= 90 ? Theme.failed : c >= 75 ? Theme.amber : Theme.muted)
                    }
                    // What this chat has spent. Quiet by default — it is a fact, not an alarm.
                    if let t = row.totalTokens {
                        Text(Costs.tokens(t))
                            .font(Theme.mono(Type.micro)).foregroundColor(Theme.faint)
                    }
                    Text(row.ago).font(Theme.mono(Type.small)).foregroundColor(Theme.faint)
                    Image(systemName: row.isBackground
                          ? "arrow.down.right.and.arrow.up.left.circle" : "arrow.up.forward.app.fill")
                        .font(.system(size: 10.5)).foregroundColor(hover ? tint : Theme.faint)
                }

                if let p = row.lastPrompt, !p.isEmpty {
                    Text("You: \(p)")
                        .font(Theme.mono(Type.small)).foregroundColor(Theme.muted)
                        .lineLimit(1).truncationMode(.tail)
                }

                // Tool name reads as a link, argument stays quiet — the reference's "Bash cargo test".
                HStack(spacing: 5) {
                    if let why = row.died {
                        Image(systemName: "xmark.octagon.fill")
                            .font(.system(size: 10)).foregroundColor(Theme.failed)
                        Text("died · \(why)").font(Theme.mono(Type.small)).foregroundColor(Theme.failed)
                    } else if let t = row.tool {
                        Text(t).font(Theme.mono(Type.small)).foregroundColor(Theme.tool)
                    }
                    if row.dormantBlocked, let q = row.blockedQuestion {
                        Image(systemName: "pause.circle")
                            .font(.system(size: 10)).foregroundColor(Theme.faint)
                        Text("blocked · \(q)")
                            .font(Theme.mono(Type.small)).foregroundColor(Theme.muted)
                            .lineLimit(1).truncationMode(.tail)
                    } else if row.died == nil {
                        Text(row.tasks?.current
                             ?? row.activity
                             ?? (row.waiting ? "waiting for your input"
                                 : row.isWorking ? "working"
                                 : row.justCompleted ? "completed" : "idle"))  // never raw phase
                            .font(Theme.mono(Type.small))
                            // Weight, not hue: the palette keeps its three semantic colours.
                            .foregroundColor(row.waiting ? Theme.waiting
                                             : row.justCompleted ? Theme.muted : Theme.faint)
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
        .onHover { h in withAnimation(Motion.hover) { hover = h } }
        .onTapGesture { if row.canJump { onJump() } }
        .help(row.isBackground ? "Background session — opens a tab, attach command copied"
              : row.precise ? "Jump to this session in \(row.terminal)"
              : "Raise \(row.terminal) — it exposes no per-tab focus API")
    }

    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(Theme.mono(Type.micro)).foregroundColor(color)
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
    /// The limits live along the bottom, out of the header's scramble and off the bar entirely.
    static let footerHeight: CGFloat = 30
    static var height: CGFloat { headerHeight + 1 + listHeight + 1 + footerHeight }
    @ObservedObject var store: AgentStore
    @ObservedObject var status: StatusStore
    // A stranger's first open is the one that decides whether they keep it.
    @State private var mode: PanelMode = Prefs.shared.seenWelcome ? .sessions : .welcome
    @State private var hooksReady = Setup.hooksInstalled()
    @State private var installing = false
    @ObservedObject private var surfaces = Surfaces.shared

    /// Settings are a panel mode like the others, so there is one way in and one way back.
    private var gearChip: some View {
        Image(systemName: "gearshape")
            .font(.system(size: 9)).foregroundColor(Theme.muted)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Capsule().fill(Theme.raised))
            .contentShape(Capsule())
            .onTapGesture {
                withAnimation(Motion.shell) {
                    if case .settings = mode { mode = .sessions } else { mode = .settings }
                }
            }
            .help("settings")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                agentPicker
                Spacer()
                if !hooksReady {
                    HStack(spacing: 4) {
                        Image(systemName: installing ? "hourglass" : "wand.and.stars")
                            .font(.system(size: 10))
                        Text(installing ? "setting up…" : "set up hooks")
                            .font(Theme.mono(Type.small))
                    }
                    .foregroundColor(Theme.amber)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Theme.amber.opacity(0.12)))
                    .contentShape(Capsule())
                    .onTapGesture {
                        guard !installing else { return }
                        installing = true
                        Setup.install { ok in installing = false; hooksReady = ok }
                    }
                }
                gearChip
                costChip
                if store.workingCount > 0 { pill("\(store.workingCount) working", Theme.working) }
                if store.waitingCount > 0 { pill("\(store.waitingCount) waiting", Theme.waiting) }
                if store.blockedCount > 0 { pill("\(store.blockedCount) blocked", Theme.faint) }
                Text("\(store.rows.count)").font(Theme.mono(Type.small)).foregroundColor(Theme.faint)
            }
            .padding(.horizontal, 14)
            .frame(height: PanelView.headerHeight)

            Rectangle().fill(Theme.hairline).frame(height: 0.7)

            if case .welcome = mode {
                WelcomeView { Prefs.shared.seenWelcome = true; withAnimation(Motion.content) { mode = .sessions } }
                    .frame(height: PanelView.listHeight)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            } else if case .settings = mode {
                SettingsView { back() }
                    .frame(height: PanelView.listHeight)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            } else if case .costs = mode {
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
                        .font(Theme.name(Type.title)).foregroundColor(Theme.muted)
                    Text(store.hasRefreshed
                         ? "start one with `claude`, `codex` or `cursor-agent`"
                         : "reading Claude Code, Codex and Cursor")
                        .font(Theme.mono(Type.small)).foregroundColor(Theme.faint)
                    if !hooksReady {
                        Text("live events and approvals need hooks — one click, backed up first")
                            .font(Theme.mono(Type.small)).foregroundColor(Theme.amber)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: PanelView.rowGap) {
                        ForEach(store.rows) { row in
                            AgentRowView(row: row, model: status.quota.model,
                                         onPlan: store.hooks.plans[row.agent.sessionId].map { _ in
                                             { withAnimation(Motion.shell) {
                                                   mode = .plan(session: row.agent.sessionId,
                                                                title: row.displayName)
                                               } }
                                         },
                                         // A card that timed out is otherwise unreachable.
                                         onAnswer: store.hooks.pendingQuestions[row.agent.sessionId]
                                             .flatMap { q -> (() -> Void)? in
                                                 guard q.deadline > Date() else { return nil }
                                                 return { _ = store.onRowActivate?(row) }
                                             },
                                         onConsole: row.agent.vendor == .claude
                                             ? { store.onOpenConsole?(row.agent.sessionId) } : nil)
                                        { store.jump(row) }
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, PanelView.listPadding)
                }
                .frame(height: PanelView.listHeight)
                .scrollIndicators(.never)
                .clipped()
            }

            Rectangle().fill(Theme.hairline).frame(height: 0.7)
            limitsFooter
        }
        .frame(width: PanelView.width, height: PanelView.height)
    }

    /// What is left, along the bottom. It used to be wedged into the header between the picker
    /// and the chips, and repeated on the bar where it cost more width than it was worth; down
    /// here there is room to say when each window refills, which the bar never had.
    private var limitsFooter: some View {
        let q = quota(for: store.effectiveVendor)
        return HStack(spacing: 7) {
            if q.fiveHourPct == nil && q.sevenDayPct == nil {
                Text("\(store.effectiveVendor.label) publishes no limits")
                    .font(Theme.mono(Type.small)).foregroundColor(Theme.faint)
            } else {
                window("5h", q.fiveHourPct, q.fiveHourResets)
                if store.effectiveVendor == .claude,
                   let r = status.quota.burnPerHour, r >= 0.5 {
                    HStack(spacing: 3) {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 10)).foregroundColor(burnTint)
                        Text(Quota.rate(r)).font(Theme.mono(Type.small)).foregroundColor(burnTint)
                        if let e = status.quota.exhaustsIn, e < 6 * 3600 {
                            Text("· full in \(Quota.short(e))")
                                .font(Theme.mono(Type.small)).foregroundColor(Theme.faint)
                        }
                    }
                }
                Text("|").font(Theme.mono(Type.small)).foregroundColor(Theme.hairline)
                window("7d", q.sevenDayPct, q.sevenDayResets)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: PanelView.footerHeight)
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
            Text(label).font(Theme.label(Type.body)).foregroundColor(Theme.text)
            // What is LEFT, and it says so. A bare "11%" next to a clock reads as readily as
            // "11% used" as "11% left", and those mean opposite things. The tint still keys on
            // the consumed figure, so red still means nearly gone.
            Text(pct.map { "\(max(0, 100 - $0))% left" } ?? "—")
                .font(Theme.label(Type.body)).foregroundColor(Quota.tint(pct))
            Text(Quota.remaining(resets)).font(Theme.mono(Type.small)).foregroundColor(Theme.faint)
        }
    }

    /// Tap to move to the next agent you actually run. One control, no settings pane: the
    /// header then reports that agent's windows and that agent's spend.
    private var agentPicker: some View {
        let v = store.effectiveVendor
        let many = store.vendorsPresent.count > 1
        return HStack(spacing: 4) {
            Image(systemName: "bolt.horizontal.fill")
                .font(.system(size: 9)).foregroundColor(Theme.agentTint)
            Text(v.label).font(Theme.label(Type.body)).foregroundColor(Theme.text)
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)   // never wrap the name
                .contentTransition(.opacity)
            if many {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9)).foregroundColor(Theme.faint)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(Theme.raised))
        .contentShape(Capsule())
        // The names differ in width, so the pill has to resize on the same curve the label
        // crossfades on or the two read as separate events.
        .animation(Motion.content, value: v)
        .contentShape(Capsule())
        .onTapGesture { withAnimation(Motion.content) { store.cycleVendor() } }
    }

    /// The selected agent's own limits. Claude reports through its status line, Codex in its
    /// rollout stream, Cursor not at all.
    private func quota(for v: Vendor) -> Quota {
        switch v {
        case .claude: return status.quota
        case .codex:  return CodexSource.quota
        case .cursor: return Quota()
        }
    }

    private func back() {
        // Settings' "What each agent can do" clears the flag rather than knowing about panel
        // modes, so this is where asking again turns into showing it again.
        withAnimation(Motion.shell) { mode = Prefs.shared.seenWelcome ? .sessions : .welcome }
    }

    private var costChip: some View {
        let today = Costs.spend(Costs.today(store.costTable), for: store.effectiveVendor)
        return HStack(spacing: 3) {
            Image(systemName: "dollarsign.circle").font(.system(size: 10))
            Text(store.costTable.isEmpty ? "cost" : Costs.dollars(today))
                .font(Theme.mono(Type.small))
        }
        .foregroundColor(Theme.muted)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(Theme.raised))
        .contentShape(Capsule())
        .onTapGesture {
            withAnimation(Motion.shell) {
                if case .costs = mode { mode = .sessions } else { mode = .costs }
            }
            if case .costs = mode { store.refreshCosts() }
        }
    }

    private func pill(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(Theme.label(Type.small)).foregroundColor(color)
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
                                    Text(r).font(Theme.mono(Type.micro))
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
                                Text(full).font(Theme.mono(Type.small)).foregroundColor(Theme.muted)
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
                                        Text(t).font(Theme.mono(Type.small)).foregroundColor(Theme.faint)
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
            Text(title).font(Theme.mono(Type.micro)).foregroundColor(Theme.faint).kerning(0.8)
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
                    Text(agentName).font(Theme.label(Type.title)).foregroundColor(Theme.text).lineLimit(1)
                    Text(approval.tool)
                        .font(Theme.mono(Type.micro)).foregroundColor(Theme.waiting)
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(Capsule().fill(Theme.waiting.opacity(0.14)))
                }
                Text(approval.detail)
                    .font(Theme.mono(Type.small)).foregroundColor(Theme.muted)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if approval.plan == nil, context == nil, let onExpand {
                Text("context ⌘⌥E")
                    .font(Theme.label(Type.body)).foregroundColor(Theme.muted)
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
            .font(Theme.label(Type.body))
            .foregroundColor(hot ? Theme.bg : tint)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(hot ? tint : tint.opacity(0.14)))
            .contentShape(Rectangle())
            .onHover { h in withAnimation(Motion.hover) { hover(h) } }
            .onTapGesture(perform: act)
    }
}

/// A blocked question, answerable in one click.
struct QuestionCard: View {
    let question: Question
    let agentName: String
    /// Which of the ask's questions is on screen, and what has been chosen so far.
    let step: Int
    let picks: [String: [String]]
    /// Free text stands in for a pick; the card treats either as an answer.
    let typed: [String: String]
    let typingFor: String?
    let allAnswered: Bool
    /// The hook has gone and Claude is asking in the chat; this card is a copy, not a way in.
    let handedOver: Bool
    /// When the grace last reset, and how long it runs. The card counts down from these and
    /// resets whenever an interaction pushes graceBase forward.
    let graceBase: Date
    let graceLength: TimeInterval
    let onPick: (String) -> Void
    let onType: (String) -> Void
    let onBeginType: () -> Void
    let onConfirm: () -> Void
    let onSubmit: () -> Void
    let onStep: (Int) -> Void
    /// Leave the card and land in the session's own terminal, question still pending.
    let onJump: () -> Void
    /// A plain-language read of this question, once it has been asked for.
    let explanation: String?
    let explaining: Bool
    let onExplain: () -> Void
    @State private var hot: String?
    @FocusState private var writing: Bool

    private var item: QuestionItem { question.items[min(step, question.items.count - 1)] }
    private var chosen: [String] { picks[item.text] ?? [] }
    private var text: String { typed[item.text] ?? "" }
    private var typing: Bool { typingFor == item.text }
    private var answered: Bool { !chosen.isEmpty || !text.trimmingCharacters(in: .whitespaces).isEmpty }
    private func done(_ i: Int) -> Bool {
        let q = question.items[i]
        return !(picks[q.text] ?? []).isEmpty
            || !(typed[q.text] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }
    private var doneCount: Int { question.items.indices.filter(done).count }
    private var isLast: Bool { step == question.items.count - 1 }
    /// The focused option decides what the preview shows; hover wins, else the first choice.
    private var focused: QuestionOption? {
        item.options.first { $0.label == hot } ?? item.options.first { chosen.contains($0.label) }
            ?? item.options.first
    }
    /// Decided by the question, not by whichever row the cursor is over. Per-option, crossing
    /// the gap between two options cleared `hot`, dropped the pane, and snapped the card 230pt
    /// narrower — then back on the next row. That oscillation is the flake in the recording,
    /// and it also matches the tool's own contract: any option with a preview puts the whole
    /// question in the side-by-side layout.
    private var showsPreview: Bool { item.options.contains { !$0.preview.isEmpty } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            // Only the options scroll. Four long options overran the card, and what fell off
            // the bottom was the free-text box and the submit button — so a question you could
            // read was one you could not answer. The controls stay put; the reading scrolls.
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 8) {
                    if explaining || explanation != nil { explainer }
                    HStack(alignment: .top, spacing: 0) {
                        options
                        if showsPreview { preview }
                    }
                }
            }
            if !handedOver { other.padding(.horizontal, 16) }
            footer
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - parts

    private var header: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().fill(Theme.waiting.opacity(0.16)).frame(width: 24, height: 24)
                Image(systemName: "questionmark")
                    .font(.system(size: 11, weight: .bold)).foregroundColor(Theme.waiting)
            }
            // Which session is asking, before what it is asking.
            if let p = question.project, p != agentName {
                Text(p).font(Theme.label(Type.title)).foregroundColor(Theme.text).lineLimit(1)
                Text("·").font(Theme.label(Type.title)).foregroundColor(Theme.faint)
            }
            Text(agentName).font(Theme.label(Type.title)).foregroundColor(Theme.muted)
                .lineLimit(1).truncationMode(.tail).layoutPriority(-1)
            if !item.header.isEmpty {
                Text(item.header)
                    .font(Theme.mono(Type.micro)).foregroundColor(Theme.waiting)
                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                    .background(Capsule().fill(Theme.waiting.opacity(0.14)))
            }
            Spacer(minLength: 6)
            // Not every ask is legible to the person being asked. This costs a headless call of
            // its own, so it is a button rather than something the card does on its own.
            if explanation == nil {
                HStack(spacing: 3) {
                    Image(systemName: explaining ? "hourglass" : "lightbulb")
                        .font(.system(size: 9, weight: .bold))
                    Text(explaining ? "explaining…" : "explain").font(Theme.mono(Type.micro))
                }
                .foregroundColor(explaining ? Theme.faint : Theme.amber)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().stroke(explaining ? Theme.hairline
                                             : Theme.amber.opacity(0.4)))
                .fixedSize()
                .contentShape(Capsule())
                .onTapGesture { if !explaining { onExplain() } }
            }
            if explaining {
                // Counting down while the reader waits to be told what the question means reads
                // as a deadline they are losing. The wait is held open, so say so instead.
                HStack(spacing: 3) {
                    Image(systemName: "pause.circle").font(.system(size: 10))
                    Text("held").font(Theme.mono(Type.small))
                }
                .foregroundColor(Theme.faint)
            } else if !handedOver {
                // Time left before the question hands to the chat. Any interaction resets it;
                // let it run out and the card becomes a read-only copy of the chat picker.
                TimelineView(.periodic(from: graceBase, by: 1)) { ctx in
                    let left = max(0, Int((graceBase.addingTimeInterval(graceLength))
                        .timeIntervalSince(ctx.date).rounded(.up)))
                    HStack(spacing: 3) {
                        Image(systemName: "timer").font(.system(size: 10))
                        Text("\(left)s").font(Theme.mono(Type.small)).monospacedDigit()
                    }
                    .foregroundColor(left <= 10 ? Theme.amber : Theme.faint)
                }
            }
            // How many questions there are, before you answer the first one.
            if question.items.count > 1 {
                HStack(spacing: 5) {
                    // Each pip is a way in: reading all four before answering any should not
                    // require knowing a chord exists.
                    HStack(spacing: 3) {
                        ForEach(0..<question.items.count, id: \.self) { i in
                            Circle()
                                .fill(done(i) ? Theme.working : Theme.faint)
                                .opacity(done(i) || i == step ? 1 : 0.4)
                                .frame(width: 6, height: 6)
                                .overlay(Circle()
                                    .stroke(Theme.waiting, lineWidth: i == step ? 1.5 : 0)
                                    .frame(width: 11, height: 11))
                                .padding(4)
                                .contentShape(Rectangle())
                                .onTapGesture { onStep(i) }
                        }
                    }
                    Text("\(step + 1) of \(question.items.count)")
                        .font(Theme.mono(Type.small)).foregroundColor(Theme.faint)
                    // Arrows belong to whatever is focused behind this panel, so the dots are
                    // the way across and saying so beats leaving it to be discovered.
                    Text("· click a dot to jump")
                        .font(Theme.mono(Type.micro)).foregroundColor(Theme.faint.opacity(0.75))
                }
            }
        }
        .padding(.horizontal, 16)
    }

    /// What the question means, in words that do not assume the codebase. Sits above the
    /// options and inside the same scroll, so it can be long without costing anyone a control.
    private var explainer: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "lightbulb")
                .font(.system(size: 10)).foregroundColor(Theme.amber)
                .frame(width: 15, height: 15)
            if let explanation {
                Text(Explain.split(explanation).lead)
                    .font(Theme.mono(Type.small)).foregroundColor(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("reading the question…")
                    .font(Theme.mono(Type.small)).foregroundColor(Theme.faint)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .padding(.horizontal, 16)
    }

    private var explainedOptions: [Int: String] {
        explanation.map { Explain.split($0).byIndex } ?? [:]
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The whole question, wrapped. Real ones reach 444 characters.
            Text(item.text)
                .font(Theme.name(Type.title)).foregroundColor(Theme.text)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(item.options.prefix(4).enumerated()), id: \.offset) { i, opt in
                    let on = chosen.contains(opt.label)
                    HStack(alignment: .top, spacing: 9) {
                        Text("\(i + 1)")
                            .font(Theme.mono(Type.small))
                            .foregroundColor(on ? Theme.waiting : Theme.faint)
                            .frame(width: 15, height: 15)
                            .overlay(RoundedRectangle(cornerRadius: 4)
                                .stroke(on ? Theme.waiting.opacity(0.4) : Theme.hairline))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(opt.label)
                                .font(Theme.label(Type.title)).foregroundColor(Theme.text)
                                .fixedSize(horizontal: false, vertical: true)
                            // Every option in every real ask carries one of these.
                            if !opt.detail.isEmpty {
                                Text(opt.detail)
                                    .font(Theme.mono(Type.small)).foregroundColor(Theme.faint)
                                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                            }
                            // What picking THIS one means, under the option it is about — the
                            // explanation is useless three options away from what it describes.
                            if let why = explainedOptions[i + 1] {
                                HStack(alignment: .top, spacing: 5) {
                                    Image(systemName: "lightbulb")
                                        .font(.system(size: 9)).foregroundColor(Theme.amber)
                                    Text(why)
                                        .font(Theme.mono(Type.small))
                                        .foregroundColor(Theme.amber.opacity(0.85))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(.top, 1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 9).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8)
                        .fill(on ? Theme.waiting.opacity(0.10)
                              : hot == opt.label ? Theme.raised : Color.clear))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke(on ? Theme.waiting.opacity(0.28) : Color.clear))
                    .contentShape(Rectangle())
                    .onHover { h in withAnimation(Motion.hover) { hot = h ? opt.label : nil } }
                    .onTapGesture { if !handedOver { onPick(opt.label) } }
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Typing beats hunting for the option that almost fits, and Claude's own picker offers it,
    /// so its absence read as the notch losing an answer rather than never having taken one.
    private var other: some View {
        let on = !text.isEmpty
        return HStack(alignment: .top, spacing: 9) {
            Image(systemName: "pencil")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(on || typing ? Theme.waiting : Theme.faint)
                .frame(width: 15, height: 15)
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .stroke(on ? Theme.waiting.opacity(0.4) : Theme.hairline))
            if typing {
                TextField("", text: Binding(get: { text }, set: onType))
                    .textFieldStyle(.plain)
                    .font(Theme.label(Type.title)).foregroundColor(Theme.text)
                    .focused($writing)
                    .onAppear { writing = true }
                    .onSubmit { isLast ? onSubmit() : onConfirm() }
            } else {
                Text(on ? text : "or type your own answer")
                    .font(Theme.label(Type.title))
                    .foregroundColor(on ? Theme.text : Theme.faint)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(on ? Theme.waiting.opacity(0.10) : typing ? Theme.raised : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(on || typing ? Theme.waiting.opacity(0.28) : Theme.hairline.opacity(0.6)))
        .contentShape(Rectangle())
        .onTapGesture { onBeginType() }
    }

    private var preview: some View {
        // The column is reserved for the whole question so hovering cannot resize the card,
        // but an option with no preview shows empty space rather than a label over nothing.
        let text = focused?.preview ?? ""
        return VStack(alignment: .leading, spacing: 6) {
            if !text.isEmpty {
                Text("PREVIEW")
                    .font(Theme.mono(Type.micro)).foregroundColor(Theme.agentTint).tracking(1.2)
                Text(text)
                    .font(Theme.mono(Type.small)).foregroundColor(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.top, 2)
        .frame(width: 230, alignment: .leading)
        .overlay(alignment: .leading) {
            Rectangle().fill(text.isEmpty ? Color.clear : Theme.hairline).frame(width: 1)
        }
    }

    /// Always visible, because a card with no button reads as a card with nothing to do — and
    /// on the last question the difference between "answered" and "submitted" is invisible
    /// unless something says so.
    private var footer: some View {
        let last = isLast
        return HStack(spacing: 10) {
            if handedOver {
                // The chat owns it now. The card stays so the question is readable in both
                // places, but it is a copy — the only thing left to do here is go there.
                Text("waiting for your answer in the chat")
                    .font(Theme.mono(Type.small)).foregroundColor(Theme.waiting)
                Spacer(minLength: 0)
                Text("go to the chat")
                    .font(Theme.mono(Type.small)).foregroundColor(Theme.text)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().stroke(Theme.hairline))
                    .contentShape(Capsule())
                    .onTapGesture(perform: onJump)
            } else {
            Text(typing ? (isLast ? (allAnswered ? "⏎ to submit" : "⏎ for what is missing")
                                  : "⏎ for the next question")
                        : item.multi ? "\(chosen.count) selected · ⌘⌥1–4 toggles"
                                     : "⌘⌥1–4 to choose")
                .font(Theme.mono(Type.small)).foregroundColor(Theme.faint)
            // Answering in the notch is one way; taking it to the chat is the other.
            Text("answer in chat →")
                .font(Theme.mono(Type.small)).foregroundColor(Theme.muted)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().stroke(Theme.hairline))
                .contentShape(Capsule())
                .onTapGesture(perform: onJump)
            Spacer(minLength: 0)
            if question.items.count > 1 {
                Text("\(doneCount) of \(question.items.count) answered")
                    .font(Theme.mono(Type.small))
                    .foregroundColor(doneCount == question.items.count ? Theme.working : Theme.faint)
            }
            if !last {
                button("next", filled: false, on: answered, action: onConfirm)
            }
            // Always present, never automatic: nothing is sent until this is pressed, and it
            // stays inert until every question in the ask has an answer.
            button("submit", filled: true, on: true, action: onSubmit)
                .opacity(allAnswered ? 1 : 0.55)
            }
        }
        .padding(.horizontal, 16)
    }

    private func button(_ title: String, filled: Bool, on: Bool,
                        action: @escaping () -> Void) -> some View {
        Text(title)
            .font(Theme.label(Type.body))
            .foregroundColor(!on ? Theme.faint : filled ? Theme.bg : Theme.text)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(Capsule().fill(on && filled ? Theme.waiting : Theme.raised))
            .overlay(Capsule().stroke(on && !filled ? Theme.hairline : Color.clear))
            .contentShape(Capsule())
            .onTapGesture { if on { action() } }
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
