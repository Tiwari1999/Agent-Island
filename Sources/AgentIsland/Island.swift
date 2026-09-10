import AppKit
import Carbon.HIToolbox
import SwiftUI

private final class Panel: NSPanel {
    /// Key only while a free-text field is live. A panel that can always become key spends the
    /// first click becoming it instead of delivering it to the row underneath — the "I had to
    /// click twice" bug — and pulls focus out of the editor behind on every option click.
    var keyable = false
    override var canBecomeKey: Bool { keyable }
}

/// A nonactivating panel is never the key window, so AppKit spends the first click activating it
/// instead of delivering it to the control underneath — the classic "I had to click twice".
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @MainActor required init(rootView: Content) { super.init(rootView: rootView) }
    @MainActor required dynamic init?(coder: NSCoder) { fatalError("not used") }
}

struct PeekPayload: Equatable {
    let session: String
    let title: String
    let message: String
    let needsInput: Bool
}

enum IslandState: Equatable {
    case collapsed, peek(PeekPayload), approval(Approval), question(Question), expanded
    case console(String)
}

/// The window is created once at its maximum footprint and never resized — the window server
/// does not interpolate content across a live resize, which is what makes frame animation stutter.
@MainActor
final class Island: NSObject, ObservableObject {
    @Published var state: IslandState = .collapsed
    /// Expanded context on the current approval card. One-way per card: reading is a commitment
    /// the hook is told about (via the hold file), so collapsing back would lie to it.
    @Published var approvalContext: ApprovalContext?
    private let hold = ApprovalHold()
    /// Watches for a click outside the card. The panel never takes focus, so this is the only
    /// way to notice one — without it a card could only be answered or waited out.
    private var outsideClick: Any?
    /// A hold that belongs to the pending question rather than to its card, so the two cannot
    /// be confused with the approval hold running beside them.
    private var heldQuestion: String?
    private var expiryWork: DispatchWorkItem?
    /// Which question of the ask is on screen, and what has been chosen so far.
    @Published var questionStep = 0
    /// Whose picks/typed/step these are. The card can be closed and reopened from the row;
    /// the answer-so-far belongs to the question, not to the card being on screen, so it is
    /// only cleared when a genuinely different question takes over.
    private var answeringId: String?
    /// When the grace last reset. Any interaction pushes it forward; the countdown on the
    /// card and the hook's fall-through both measure from here.
    @Published var graceBase = Date()
    /// Must match the question hook's AGENTISLAND_Q_GRACE default; the card counts down this
    /// long and the hook falls through after the same idle span.
    static let graceSeconds: TimeInterval = 60
    @Published var picks: [String: [String]] = [:]
    /// Free text the reader typed instead of picking, keyed the same way as `picks`.
    @Published var typed: [String: String] = [:]
    /// Which question's field is live — the only time this panel takes keyboard focus.
    @Published var typingFor: String?
    /// Questions whose hook has gone: Claude is asking in the chat now, and the card stays
    /// as a read-only copy so the question is visible in both places rather than vanishing.
    @Published var handedOver: Set<String> = []
    private let frames = FrameMeter()
    @Published var revealed = false
    @Published var notchWidth: CGFloat = 0
    @Published var notchHeight: CGFloat = 32

    static let maxSize = NSSize(width: 860, height: 420)
    /// The console's footprint. Sized to be read at a glance rather than lived in; the window is
    /// created once at maxSize, so growing this later costs nothing structurally.
    static let consoleSize = NSSize(width: 640, height: 320)
    /// Breathing room under the camera housing — enough that text never touches the bezel,
    /// small enough that the card still reads as hanging off the notch rather than floating.
    static let notchClearance: CGFloat = 3

    private var window: Panel?
    private var poll: Timer?
    private let sensor = HoverSensor()
    private var clickOutside: Any?
    private var clickInside: Any?
    private var peekWork: DispatchWorkItem?
    private var heartbeat: Timer?
    private var approvalWork: DispatchWorkItem?
    private var questionWork: DispatchWorkItem?
    private var dwell: DispatchWorkItem?
    /// NN/g puts the hover-intent threshold at 300-500ms; 0ms opened the panel on every trip
    /// to the menu bar, which is the top complaint across every shipping notch app.
    private static let hoverDwell: TimeInterval = 0.18
    private var outsideTicks = 0
    private let store: AgentStore
    private let status: StatusStore

    init(store: AgentStore, status: StatusStore) {
        self.store = store; self.status = status; super.init()
    }

    /// The screen the user is actually on. Pinning to the launch screen meant a popup fired on a
    /// display they were no longer looking at.
    private var activeScreen: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main ?? NSScreen.screens.first
    }
    private var pinned: NSScreen?
    private var screen: NSScreen? { pinned ?? activeScreen }

    /// Re-home the window on the active display. Safe to do while collapsed because nothing is
    /// drawn then, so the move cannot be seen.
    @discardableResult
    private func followActiveScreen() -> Bool {
        guard let window, let target = activeScreen else { return false }
        if let current = pinned, current.frame == target.frame { return false }
        pinned = target
        measureNotch(target)
        let size = Self.maxSize
        window.setFrame(NSRect(x: target.frame.midX - size.width / 2,
                               y: target.frame.maxY - size.height,
                               width: size.width, height: size.height),
                        display: false)
        sensor.install(on: target, notchWidth: notchWidth, notchHeight: notchHeight)
        Diagnostics.log("island moved to screen \(target.frame)")
        return true
    }

    func install() {
        guard let screen else { return }
        pinned = screen
        measureNotch(screen)

        let size = Self.maxSize
        let origin = NSPoint(x: screen.frame.midX - size.width / 2,
                             y: screen.frame.maxY - size.height)
        let panel = Panel(contentRect: NSRect(origin: origin, size: size),
                          styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = FirstMouseHostingView(rootView: RootView(island: self, store: store, status: status))
        panel.orderFrontRegardless()
        window = panel

        heartbeat = Approvals.startHeartbeat()

        store.onOpenConsole = { [weak self] sid in self?.openConsole(sid) }
        store.onBackgroundAttach = { [weak self] name in
            self?.peek(PeekPayload(session: "", title: name,
                                   message: "attach command copied — paste in the new tab",
                                   needsInput: false))
        }

        store.hooks.onApproval = { [weak self] approval in
            guard let self else { return }
            self.present(approval)
            let name = self.store.name(for: approval.session) ?? "agent"
            Notifier.notify(title: "\(name) needs permission",
                            body: "\(approval.tool): \(approval.detail)", key: approval.session)
        }

        // A row that is blocked on a question answers it; jumping to the terminal would be
        // answering the wrong way round.
        store.onRowActivate = { [weak self] row in
            guard let self else { return false }
            guard let q = self.store.hooks.pendingQuestions[row.agent.sessionId],
                  q.deadline > Date() else { return false }
            self.ask(q)
            return true
        }
        store.hooks.onQuestion = { [weak self] question in
            guard let self else { return }
            self.ask(question)
            let name = self.store.name(for: question.session)
                ?? question.project ?? "agent"
            Notifier.notify(title: name, body: question.items[0].text, key: question.session)
        }

        store.hooks.onAttention = { [weak self] session, message, needsInput in
            guard let self else { return }
            // A session we cannot name is one we never show as a row either -- background
            // agents spawned by another agent, which are deliberately excluded. Announcing
            // their finishes both leaked a raw id and reported work the user never started.
            guard let name = self.store.name(for: session) else { return }
            self.peek(PeekPayload(session: session, title: name,
                                  message: needsInput ? message : "finished",
                                  needsInput: needsInput))
            if needsInput { Notifier.notify(title: name, body: message, key: session) }
        }

        // One chord summons the console for whoever needs you most; pressing it again closes it.
        Hotkeys.shared.bindLasting([(kVK_ANSI_K, Hotkeys.cmdOpt, { [weak self] in
            guard let self else { return }
            if case .console = self.state { self.closeConsole() }
            else if let s = self.leadSession { self.openConsole(s) }
        })])

        sensor.install(on: screen, notchWidth: notchWidth, notchHeight: notchHeight)
        sensor.onEnter = { [weak self] in
            guard let self else { return }
            // Reveal is instant (the 100ms affordance rule); expanding waits for intent.
            withAnimation(.easeOut(duration: 0.14)) { self.revealed = true }
            self.dwell?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.state == .collapsed else { return }
                self.expand()
            }
            self.dwell = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverDwell, execute: work)
        }
        sensor.onExit = { [weak self] in
            guard let self else { return }
            self.dwell?.cancel()
            // Always clear the reveal, even if a card took over the notch while the pointer was
            // on it. Gating this on `.collapsed` stranded `revealed = true` whenever a question
            // or peek arrived mid-hover, so the bar drew at its wide hover width once the card
            // dismissed — an oversized resting bar that only a fresh hover cycle fixed.
            withAnimation(.easeOut(duration: 0.16)) { self.revealed = false }
        }

        repoll()
    }

    private func measureNotch(_ screen: NSScreen) {
        let inset = screen.safeAreaInsets.top
        notchHeight = inset > 0 ? inset : 28
        if inset > 0, let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            notchWidth = max(100, screen.frame.width - l.width - r.width)
        } else {
            notchWidth = 0
        }
    }

    /// The strip that reveals the island — the notch plus a little breathing room.
    private var hotRect: NSRect {
        guard let screen else { return .zero }
        let w = max(notchWidth, 120) + 150
        return NSRect(x: screen.frame.midX - w / 2, y: screen.frame.maxY - notchHeight,
                      width: w, height: notchHeight)
    }

    /// What the panel actually draws. Hit-testing the window instead would swallow clicks in the
    /// transparent margin, which reads to the user as "clicking outside does nothing".
    private var panelRect: NSRect {
        guard let screen else { return .zero }
        return NSRect(x: screen.frame.midX - PanelView.width / 2,
                      y: screen.frame.maxY - notchHeight - Self.notchClearance - PanelView.height,
                      width: PanelView.width,
                      height: notchHeight + Self.notchClearance + PanelView.height)
    }

    /// The toast's own rect, so it can be clicked and does not eat the desktop around it.
    private var peekRect: NSRect {
        guard let screen else { return .zero }
        let w: CGFloat = 380, h = notchHeight + Self.notchClearance + 38
        return NSRect(x: screen.frame.midX - w / 2, y: screen.frame.maxY - h, width: w, height: h)
    }

    /// The approval card is wider than a toast and must be fully clickable.
    private var approvalRect: NSRect {
        guard let screen else { return .zero }
        var w: CGFloat = 560, extra: CGFloat = 46
        if case .approval(let a) = state, a.plan != nil || approvalContext != nil {
            w = 640; extra = 300
        }
        let h = notchHeight + Self.notchClearance + extra
        return NSRect(x: screen.frame.midX - w / 2, y: screen.frame.maxY - h, width: w, height: h)
    }

    /// Questions need room for the prompt plus a row of options.
    /// The question currently on screen, and the size it needs — both the window frame and the
    /// view read these, so a card can never be drawn at a size the window did not reserve.
    func questionItem(_ q: Question) -> QuestionItem? {
        guard !q.items.isEmpty else { return nil }
        return q.items.indices.contains(questionStep) ? q.items[questionStep] : q.items[0]
    }

    func questionSize(_ q: Question) -> CGSize {
        guard let item = questionItem(q) else { return CGSize(width: 600, height: 98) }
        let w: CGFloat = item.hasPreview ? 830 : 600
        let cap = (screen?.frame.height ?? 900) * 0.62
        return CGSize(width: w, height: min(item.cardHeight(width: w), cap))
    }

    private var consoleRect: NSRect {
        guard let w = window else { return .zero }
        let size = Island.consoleSize
        let top = w.frame.maxY - notchHeight - Island.notchClearance
        return NSRect(x: w.frame.midX - size.width / 2, y: top - size.height,
                      width: size.width, height: size.height)
    }

    private var questionRect: NSRect {
        guard let screen else { return .zero }
        guard case .question(let q) = state else { return .zero }
        let size = questionSize(q)
        let h = notchHeight + Self.notchClearance + size.height
        return NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - h,
                      width: size.width, height: h)
    }

    /// Recompute which region accepts clicks. Called on every state change as well as on the
    /// poll, because waiting for the next tick left a window where clicks fell through the panel.
    private func refreshHitRegion() {
        guard let window else { return }
        // While collapsed the bar has nothing clickable, so the panel should never compete for
        // the pointer. Both windows sit at .statusBar, and a window that accepts events hides
        // everything beneath it from hit-testing — so if this one accepted them over the notch,
        // the hover sensor underneath would simply never fire. Ordering alone is not a fix:
        // orderFrontRegardless only holds until something else reorders.
        if state == .collapsed {
            window.ignoresMouseEvents = true
            return
        }
        let mouse = NSEvent.mouseLocation
        let live: NSRect
        switch state {
        case .collapsed: return   // handled above; keeps the switch total
        case .expanded: live = panelRect.union(hotRect)
        case .peek:     live = peekRect.union(hotRect)
        case .approval: live = approvalRect.union(hotRect)
        case .question: live = questionRect.union(hotRect)
        case .console:  live = consoleRect.union(hotRect)
        }
        window.ignoresMouseEvents = !live.insetBy(dx: -4, dy: -4).contains(mouse)
    }

    /// Hover is handled by the tracking area, so while collapsed this timer only needs to keep
    /// the island on the right display — 16 wakeups a second for that is pure battery burn.
    private func repoll() {
        poll?.invalidate()
        let interval: TimeInterval = state == .collapsed ? 0.75 : 0.06
        poll = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.track() }
        }
    }

    private func track() {
        guard window != nil else { return }
        // The hook has gone, so Claude is asking in the chat instead. Keep the card as a
        // read-only copy rather than dropping it: leaving the notch blank is what made the
        // question feel lost when it moved.
        if case .question(let q) = state, q.abandoned {
            if !handedOver.contains(q.id) {
                handedOver.insert(q.id)
                releaseQuestion(q.id)
                endTyping()
                Hotkeys.shared.unbind()
                refreshHitRegion()
            }
            // Answering it in the chat moves the turn on, which clears it from the store; a
            // mirror whose window has also elapsed is dropped so a dead session cannot park it.
            if store.hooks.pendingQuestions[q.session]?.id != q.id || q.deadline <= Date() {
                handedOver.remove(q.id)
                store.hooks.clearQuestion(q.id)
                dismissQuestion()
            }
            return
        }
        // Only re-home while collapsed; moving a visible panel would yank it mid-interaction.
        if state == .collapsed { followActiveScreen() }
        let mouse = NSEvent.mouseLocation
        refreshHitRegion()

        switch state {
        case .peek, .approval, .question, .console:
            return   // hold until dwell elapses or the user acts; hover must not steal it
        case .collapsed:
            // Hover belongs to HoverSensor's tracking area alone. This branch used to duplicate
            // it — setting `revealed` and calling expand() on its own schedule — so two paths
            // fought over the same state at different rates and the result depended on which
            // won. The poll now only keeps the island on the right display.
            return
        case .expanded:
            if panelRect.union(hotRect).insetBy(dx: -8, dy: -8).contains(mouse) {
                outsideTicks = 0
                return
            }
            outsideTicks += 1
            if outsideTicks >= 3 { outsideTicks = 0; collapse() }
        }
    }

    func expand() {
        guard state != .expanded else { return }
        if let v = window?.contentView { frames.start(on: v) }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) { state = .expanded }
        store.setPanelVisible(true)
        repoll()
        installClickMonitors()
        refreshHitRegion()
    }

    /// A global monitor only sees clicks delivered to other apps; a click landing on our own
    /// transparent margin needs the local one. Without both, dismissal is unreliable.
    private func installClickMonitors() {
        removeClickMonitors()
        clickOutside = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            guard let self, self.state == .expanded else { return }
            if self.panelRect.contains(NSEvent.mouseLocation) { return }
            self.collapse()
        }
        clickInside = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self, self.state == .expanded else { return event }
            let m = NSEvent.mouseLocation
            if ProcessInfo.processInfo.environment["AGENTISLAND_FRAMEPROBE"] == "1" {
                Diagnostics.log(String(format: "click probe: (%.0f,%.0f) panelRect=%@ inside=%d",
                                       m.x, m.y, NSStringFromRect(self.panelRect),
                                       self.panelRect.contains(m) ? 1 : 0))
            }
            if self.panelRect.contains(m) { return event }
            self.collapse()
            return nil
        }
    }

    private func removeClickMonitors() {
        if let m = clickOutside { NSEvent.removeMonitor(m); clickOutside = nil }
        if let m = clickInside { NSEvent.removeMonitor(m); clickInside = nil }
    }

    func collapse() {
        guard state != .collapsed else { return }
        frames.stopAndReport()
        dwell?.cancel()
        removeClickMonitors()
        outsideTicks = 0
        withAnimation(.spring(response: 0.30, dampingFraction: 0.85)) { state = .collapsed }
        store.setPanelVisible(false)
        repoll()
        // Every other transition refreshes this; collapse did not. The panel therefore kept
        // accepting events across its whole frame until the next poll — up to 750ms — and
        // swallowed the pointer before the hover sensor beneath it could see it. That is
        // exactly why the first move to the notch did nothing and the second worked.
        refreshHitRegion()
        if !hotRect.contains(NSEvent.mouseLocation) {
            withAnimation(.easeOut(duration: 0.16)) { revealed = false }
        }
    }

    func toggle() { state == .expanded ? collapse() : expand() }

    /// Drop a toast below the notch, hold, spring back. Never interrupts an open panel.
    func peek(_ payload: PeekPayload) {
        followActiveScreen()
        guard state != .expanded else { return }
        peekWork?.cancel()
        withAnimation(.spring(response: 0.34, dampingFraction: 0.80)) { state = .peek(payload) }
        refreshHitRegion()
        let work = DispatchWorkItem { [weak self] in
            guard let self, case .peek = self.state else { return }
            withAnimation(.spring(response: 0.30, dampingFraction: 0.85)) { self.state = .collapsed }
        }
        peekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: work)
    }

    /// Asks that arrived while another card was up. Ten agents can block on the same second, and
    /// replacing the visible card silently abandoned the earlier one: its hook waited out the
    /// full timeout and then fell through to the terminal, which reads as a missed approval.
    private var queuedApprovals: [Approval] = []
    private var queuedQuestions: [Question] = []

    private var showingCard: Bool {
        if case .approval = state { return true }
        if case .question(let q) = state { return !isStaleCard(q) }
        return false
    }

    /// A question card nobody is actively answering: it was handed to the chat, or its hook has
    /// gone. Such a card is informational and must yield the stage to a live one.
    private func isStaleCard(_ q: Question) -> Bool {
        handedOver.contains(q.id) || q.abandoned
    }

    /// Show the next thing still worth answering. Questions outrank approvals: an agent asking a
    /// question is blocked outright, while a tool approval can still fall back to the terminal.
    private func presentNext() {
        let now = Date()
        queuedQuestions.removeAll { $0.deadline <= now }
        queuedApprovals.removeAll { $0.deadline <= now }
        // Clear first: ask() and present() both treat a different card still being on screen as
        // "wait your turn", so handing them the next one mid-state queued it forever.
        if !queuedQuestions.isEmpty || !queuedApprovals.isEmpty { state = .collapsed }
        if !queuedQuestions.isEmpty { ask(queuedQuestions.removeFirst()); return }
        if !queuedApprovals.isEmpty { present(queuedApprovals.removeFirst()); return }
        withAnimation(.spring(response: 0.30, dampingFraction: 0.85)) { state = .collapsed }
    }

    /// Expand the visible approval: assemble context off-main, hold the hook open, re-arm the
    /// drop to the hook's hard ceiling instead of its base timeout.
    func expandApproval() {
        guard case .approval(let a) = state, approvalContext == nil else { return }
        hold.begin(id: a.id)
        approvalWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, case .approval(let cur) = self.state, cur.id == a.id else { return }
            self.hold.end(); self.approvalContext = nil
            Hotkeys.shared.unbind()
            self.presentNext()
        }
        approvalWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 290, execute: work)
        let trail = store.hooks.live[a.session]?.trail ?? []
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ctx = ApprovalContext.gather(for: a, trail: trail)
            Task { @MainActor in
                guard let self, case .approval(let cur) = self.state, cur.id == a.id else { return }
                withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                    self.approvalContext = ctx
                }
                self.refreshHitRegion()
            }
        }
    }

    /// An approval outranks a toast: a blocked tool is the most urgent thing on screen.
    func present(_ approval: Approval) {
        guard !showingCard else {
            if !queuedApprovals.contains(where: { $0.id == approval.id }) {
                queuedApprovals.append(approval)
            }
            return
        }
        followActiveScreen()
        peekWork?.cancel(); approvalWork?.cancel()
        hold.end(); approvalContext = nil
        Hotkeys.shared.bind([
            (kVK_ANSI_A, Hotkeys.cmdOpt, { [weak self] in self?.answer(approval, allow: true) }),
            (kVK_ANSI_D, Hotkeys.cmdOpt, { [weak self] in self?.answer(approval, allow: false) }),
            (kVK_ANSI_E, Hotkeys.cmdOpt, { [weak self] in self?.expandApproval() }),
        ])
        withAnimation(.spring(response: 0.34, dampingFraction: 0.80)) { state = .approval(approval) }
        refreshHitRegion()
        // Drop the card when the hook stops waiting, so a dead prompt can't linger.
        let work = DispatchWorkItem { [weak self] in
            guard let self, case .approval(let a) = self.state, a.id == approval.id else { return }
            self.hold.end(); self.approvalContext = nil
            Hotkeys.shared.unbind()
            self.presentNext()
        }
        approvalWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + approval.deadline.timeIntervalSinceNow,
                                      execute: work)
    }

    /// A question outranks everything: an agent is blocked until it is answered.
    func ask(_ question: Question) {
        // A question may take over from an approval, which returns to the queue rather than
        // being dropped; another question waits its turn.
        if case .approval(let a) = state, a.deadline > Date() {
            approvalWork?.cancel()
            approvalContext = nil     // it belonged to that approval, not to the one returning
            if !queuedApprovals.contains(where: { $0.id == a.id }) { queuedApprovals.insert(a, at: 0) }
        } else if case .question(let q) = state, q.id != question.id {
            if isStaleCard(q) {
                handedOver.remove(q.id)         // the leftover yields to a live question
                store.hooks.clearQuestion(q.id)
            } else {
                if !queuedQuestions.contains(where: { $0.id == question.id }) {
                    queuedQuestions.append(question)
                }
                return
            }
        }
        followActiveScreen()
        peekWork?.cancel(); questionWork?.cancel()
        // Keep the answer-so-far across a close/reopen: only a genuinely different question
        // starts clean. Tying this to whether the card was still on screen wiped every pick
        // the moment the panel was dismissed.
        if answeringId != question.id {
            answeringId = question.id
            questionStep = 0; picks = [:]; typed = [:]
            graceBase = Date()
        }
        endTyping()
        // Keys are bound per question as the sequence advances, so 1-4 always means "this
        // question's options" rather than a running index across the whole ask.
        bindKeys(question, step: questionStep)
        withAnimation(.spring(response: 0.34, dampingFraction: 0.80)) { state = .question(question) }
        // Keep the hook waiting while the card is on screen: it used to expire underneath the
        // reader after 45 seconds, taking the only way to answer with it.
        holdQuestion(question)
        watchForOutsideClick()
        refreshHitRegion()
        let work = DispatchWorkItem { [weak self] in
            guard let self, case .question(let q) = self.state, q.id == question.id else { return }
            Hotkeys.shared.unbind()
            self.presentNext()      // the hold outlives the card; only expiry ends it
        }
        questionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + question.deadline.timeIntervalSinceNow,
                                      execute: work)
    }

    private func bindKeys(_ q: Question, step: Int) {
        guard step < q.items.count else { return }
        var keys: [(key: Int, mods: Int, action: () -> Void)] =
            q.items[step].options.prefix(4).enumerated().map { i, opt in
                (Hotkeys.digits[i], Hotkeys.cmdOpt,
                 { [weak self] in self?.pick(q, step: step, option: opt.label) })
            }
        if q.items.count > 1 {
            // Arrows with this chord are taken by terminals and browsers for tab switching, so
            // registration failed silently. Shift plus the same digits jumps straight to a
            // question, which also beats stepping when you want the fourth one.
            for i in q.items.indices.prefix(4) {
                keys.append((Hotkeys.digits[i], Hotkeys.cmdOptShift,
                             { [weak self] in self?.goToStep(q, i) }))
            }
        }
        Hotkeys.shared.bind(keys)
    }

    /// Move to another question of the same ask without answering this one, so you can read
    /// them all before committing to any. Clicking a pip lands here too.
    func goToStep(_ q: Question, _ step: Int) {
        guard q.items.indices.contains(step), step != questionStep else { return }
        markInteraction(q.id)
        endTyping()     // the field belonged to the question being left
        questionStep = step
        bindKeys(q, step: step)
        withAnimation(.easeOut(duration: 0.16)) { state = .question(q) }
        refreshHitRegion()
    }

    /// Keep the hook waiting for as long as the question is answerable, whether or not its
    /// card is on screen. Tying this to the card meant one click elsewhere killed the hook,
    /// and every answer given afterwards was written to a file nobody was reading.
    private func holdQuestion(_ q: Question) {
        guard heldQuestion != q.id else { return }
        heldQuestion = q.id
        expiryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.heldQuestion == q.id else { return }
            self.releaseQuestion(q.id)
            self.store.hooks.clearQuestion(q.id)
        }
        expiryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(1, q.deadline.timeIntervalSinceNow),
                                      execute: work)
    }

    /// Hand the question to the chat: release the hook so Claude shows its own picker, and
    /// leave the card up as a read-only mirror rather than dismissing it, so the question is
    /// visible in both places until it is answered.
    /// Show the console for one session. It is a reader: the panel never becomes key, so a
    /// glance can never take the cursor out of the editor behind it.
    func openConsole(_ session: String) {
        if case .console(let cur) = state, cur == session { closeConsole(); return }
        guard !session.isEmpty else { return }
        followActiveScreen()
        peekWork?.cancel()
        // Escape belongs to the console only while it is up, then goes straight back.
        Hotkeys.shared.bind([(kVK_Escape, 0, { [weak self] in self?.closeConsole() })])
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) { state = .console(session) }
        watchForOutsideClick()
        refreshHitRegion()
    }

    func closeConsole() {
        guard case .console = state else { return }
        stopWatchingClicks()
        Hotkeys.shared.unbind()
        withAnimation(.spring(response: 0.30, dampingFraction: 0.85)) { state = .collapsed }
        refreshHitRegion()
    }

    /// The session a bare summon opens: whoever needs you, else whoever is working.
    var leadSession: String? {
        (store.rows.first { $0.waiting } ?? store.rows.first { $0.isWorking }
            ?? store.rows.first)?.agent.sessionId
    }

    func handToChat(_ q: Question) {
        Approvals.skip(q.id)
        handedOver.insert(q.id)
        releaseQuestion(q.id)
        endTyping()
        Hotkeys.shared.unbind()
        refreshHitRegion()
    }

    private func releaseQuestion(_ id: String) {
        guard heldQuestion == id else { return }
        heldQuestion = nil
        if answeringId == id { answeringId = nil; picks = [:]; typed = [:]; questionStep = 0 }
        expiryWork?.cancel(); expiryWork = nil
    }

    private func watchForOutsideClick() {
        stopWatchingClicks()
        outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in
            guard let self else { return }
            // Global monitors only see clicks outside our own windows, so arriving here is
            // already proof the click was elsewhere.
            switch self.state {
            case .question: DispatchQueue.main.async { self.dismissQuestion() }
            case .console:  DispatchQueue.main.async { self.closeConsole() }
            default: return
            }
        }
    }

    private func stopWatchingClicks() {
        if let outsideClick { NSEvent.removeMonitor(outsideClick) }
        outsideClick = nil
    }

    /// Dismiss the card without answering. The hook falls through to the terminal, and the
    /// question stays pending so the row can bring it back.
    func dismissQuestion() {
        guard case .question = state else { return }
        endTyping()
        // The card goes away; the question does not. The agent is still blocked on it, so the
        // hook keeps waiting and the row's answer button brings the card straight back.
        questionWork?.cancel()
        stopWatchingClicks()
        Hotkeys.shared.unbind()
        presentNext()
    }

    /// Record one answer and move on. A four-question ask is one card rather than four, and
    /// nothing commits until submit — moving off the last question is not an answer.
    /// Every real interaction slides the grace forward and re-stamps the mark the hook reads,
    /// so answering keeps the window open while idling lets it fall through to the chat.
    func markInteraction(_ id: String) {
        graceBase = Date()
        Approvals.touch(id)
    }

    func pick(_ question: Question, step: Int, option: String) {
        guard step < question.items.count else { return }
        markInteraction(question.id)
        let item = question.items[step]
        if item.multi {
            var chosen = picks[item.text] ?? []
            if let i = chosen.firstIndex(of: option) { chosen.remove(at: i) } else { chosen.append(option) }
            picks[item.text] = chosen
            return          // multi waits for an explicit confirm
        }
        picks[item.text] = [option]
        advance(question, from: step)
    }

    /// Confirm a multi-select question, or step past one already answered.
    func advance(_ question: Question, from step: Int) {
        // The last question never submits itself. Answering four and having the card vanish
        // under the fourth click, with no way back to revise the first, was the loudest bug.
        guard step + 1 < question.items.count else { return }
        goToStep(question, step + 1)
    }

    /// Answered by a pick or by typing — either counts, neither is assumed.
    func isAnswered(_ item: QuestionItem) -> Bool {
        !(picks[item.text] ?? []).isEmpty
            || !(typed[item.text] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    func allAnswered(_ q: Question) -> Bool { q.items.allSatisfy(isAnswered) }

    /// The only path that commits. A partial set is never sent: it takes you to the gap,
    /// which beats a dead click on a button that looks pressable.
    func submit(_ question: Question) {
        guard allAnswered(question) else {
            if let gap = question.items.firstIndex(where: { !isAnswered($0) }) {
                goToStep(question, gap)
            }
            return
        }
        endTyping()
        choose(question, picks: picks)
    }

    /// Typing needs keyboard focus, which this panel refuses by default so that clicking an
    /// option never pulls focus out of the editor behind. Take it for the field alone.
    func beginTyping(_ key: String) {
        guard typingFor != key else { return }
        if case .question(let q) = state { markInteraction(q.id) }
        typingFor = key
        (window as? Panel)?.keyable = true
        window?.makeKeyAndOrderFront(nil)
    }

    func endTyping() {
        guard typingFor != nil else { return }
        typingFor = nil
        (window as? Panel)?.keyable = false
        NSApp.deactivate()          // hand focus back to whatever had it
    }

    func choose(_ question: Question, picks: [String: [String]]) {
        stopWatchingClicks()
        defer { releaseQuestion(question.id) }
        // An ask whose questions share wording cannot be answered as a map keyed by wording:
        // the second pick overwrites the first and the write is refused. Say so rather than
        // silently closing a card whose hook is still waiting.
        // Confirm the answer was actually collected. If the hook has gone, say so rather than
        // leaving the user believing they answered.
        Approvals.wasRead(question.id) { [weak self] read in
            guard let self, !read else { return }
            let name = self.store.name(for: question.session) ?? question.project ?? "the agent"
            Diagnostics.log("question \(question.id): answered too late, the hook had gone")
            Notifier.notify(title: name,
                            body: "Answer arrived too late — answer it in the terminal instead",
                            key: question.session)
        }
        guard Approvals.answer(question, picks: picks, typed: typed) else {
            Diagnostics.log("question \(question.id): could not answer, leaving it to the terminal")
            questionWork?.cancel(); hold.end()
            store.hooks.clearQuestion(question.id)
            Hotkeys.shared.unbind()
            presentNext()
            return
        }
        questionWork?.cancel()
        hold.end()
        store.hooks.clearQuestion(question.id)
        Hotkeys.shared.unbind()
        presentNext()
    }

    func answer(_ approval: Approval, allow: Bool) {
        approvalWork?.cancel()
        hold.end(); approvalContext = nil
        Hotkeys.shared.unbind()
        Approvals.decide(approval, allow: allow)
        presentNext()
    }

    /// Clicking a toast jumps straight to the agent that raised it.
    func actOnPeek(_ payload: PeekPayload) {
        peekWork?.cancel()
        if let row = store.rows.first(where: { $0.agent.sessionId == payload.session }) {
            store.jump(row)
        }
        withAnimation(.spring(response: 0.30, dampingFraction: 0.85)) { state = .collapsed }
    }
}

private struct RootView: View {
    @ObservedObject var island: Island
    @ObservedObject var store: AgentStore
    @ObservedObject var status: StatusStore


    /// Nothing running, nothing waiting, pointer elsewhere.
    private var quiet: Bool {
        store.workingCount == 0 && store.waitingCount == 0 && !island.revealed
    }

    private var shellWidth: CGFloat {
        switch island.state {
        case .collapsed:
            let lead = store.rows.first { $0.waiting } ?? store.rows.first { $0.isWorking }
            let w = CollapsedView.sides(revealed: island.revealed, quiet: quiet,
                                        text: lead.map { $0.activity ?? $0.displayName })
            return island.notchWidth + w.left + w.right + 2 * CollapsedView.notchMargin
        case .peek:      return 380
        case .approval(let a):  return (a.plan != nil || island.approvalContext != nil) ? 640 : 560
        case .question(let q): return island.questionSize(q).width
        case .console:   return Island.consoleSize.width
        case .expanded:  return PanelView.width
        }
    }
    private var shellHeight: CGFloat {
        switch island.state {
        // Exactly the notch height. Anything shorter leaves a step where the bar meets the
        // camera housing; anything taller hangs into the window below.
        case .collapsed: return island.notchHeight
        case .peek:      return island.notchHeight + Island.notchClearance + 38
        case .approval(let a):
            return island.notchHeight + Island.notchClearance
                + ((a.plan != nil || island.approvalContext != nil) ? 300 : 46)
        case .question(let q):
            return island.notchHeight + Island.notchClearance + island.questionSize(q).height
        case .console:
            return island.notchHeight + Island.notchClearance + Island.consoleSize.height
        case .expanded:  return PanelView.height
        }
    }
    private var corner: CGFloat {
        switch island.state {
        // Exactly the notch height. Anything shorter leaves a step where the bar meets the
        // camera housing; anything taller hangs into the window below.
        case .collapsed: return island.notchHeight * 0.55
        case .peek:      return 20
        case .approval:  return 22
        case .question:  return 22
        case .console:   return 22
        case .expanded:  return 18
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                NotchShape(radius: corner)
                    .fill(Theme.bg)
                    .overlay(NotchShape(radius: corner).stroke(Theme.hairline, lineWidth: 0.7))
                    .shadow(color: .black.opacity(0.55),
                            radius: island.state == .expanded ? 24 : 8, y: 6)

                switch island.state {
                case .collapsed:
                    CollapsedView(store: store, status: status, notchWidth: island.notchWidth,
                                  revealed: island.revealed, quiet: quiet)
                case .peek(let p):
                    PeekView(title: p.title, message: p.message,
                             needsInput: p.needsInput, notchWidth: island.notchWidth)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 6)
                        .contentShape(Rectangle())
                        .onTapGesture { island.actOnPeek(p) }
                case .approval(let a):
                    ApprovalCard(
                        approval: a,
                        agentName: store.name(for: a.session) ?? "agent",
                        context: island.approvalContext,
                        onExpand: { island.expandApproval() },
                        onAllow: { island.answer(a, allow: true) },
                        onDeny:  { island.answer(a, allow: false) })
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 6)
                case .question(let q):
                    QuestionCard(
                        question: q,
                        agentName: store.name(for: q.session) ?? q.project ?? "agent",
                        step: island.questionStep,
                        picks: island.picks,
                        typed: island.typed,
                        typingFor: island.typingFor,
                        allAnswered: island.allAnswered(q),
                        handedOver: island.handedOver.contains(q.id),
                        graceBase: island.graceBase,
                        graceLength: Island.graceSeconds,
                        onPick: { island.pick(q, step: island.questionStep, option: $0) },
                        onType: {
                            island.typed[q.items[island.questionStep].text] = $0
                            island.markInteraction(q.id)
                        },
                        onBeginType: { island.beginTyping(q.items[island.questionStep].text) },
                        onConfirm: { island.advance(q, from: island.questionStep) },
                        onSubmit: { island.submit(q) },
                        onStep: { island.goToStep(q, $0) },
                        onJump: {
                            island.handToChat(q)
                            if let row = store.rows.first(where: { $0.agent.sessionId == q.session }) {
                                store.jumpToTerminal(row)
                            }
                        })
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 6)
                case .console(let sid):
                    ConsoleView(store: store, session: sid,
                                onJump: {
                                    island.closeConsole()
                                    if let row = store.rows.first(where: {
                                        $0.agent.sessionId == sid }) {
                                        store.jumpToTerminal(row)
                                    }
                                },
                                onClose: { island.closeConsole() })
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 6)
                case .expanded:
                    // Inset past the physical notch so text clears the camera, while the shape
                    // behind it still reaches the screen edge and reads as one piece with it.
                    PanelView(store: store, status: status)
                        .padding(.top, island.notchHeight + Island.notchClearance)
                }
            }
            .frame(width: shellWidth, height: shellHeight)
            .contentShape(NotchShape(radius: corner))

            Spacer(minLength: 0)
        }
        .frame(width: Island.maxSize.width, height: Island.maxSize.height, alignment: .top)
    }
}
