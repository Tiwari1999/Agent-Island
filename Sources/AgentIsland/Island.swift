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
    /// A plain-language read of a question, keyed by the question's own text. Asked for by hand,
    /// kept for as long as the card is up: the call costs about ten seconds.
    @Published var explanations: [String: String] = [:]
    @Published var explaining: Set<String> = []
    private var explainHold: Timer?
    private let frames = FrameMeter()
    @Published var revealed = false
    /// The collapsed bar has gone quiet and stepped out of the way.
    @Published var autoHidden = false
    @Published var notchWidth: CGFloat = 0
    @Published var notchHeight: CGFloat = 32

    static let maxSize = NSSize(width: 980, height: 420)
    /// The console's footprint. Sized to be read at a glance rather than lived in; the window is
    /// created once at maxSize, so growing this later costs nothing structurally.
    static let consoleSize = NSSize(width: 640, height: 356)
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
    /// to the menu bar, which is the top complaint across every shipping notch app. 180ms was
    /// still under that band and opened on the way past to something else, so it sits in it now.
    private static let hoverDwell: TimeInterval = 0.35
    private var outsideTicks = 0
    /// Opened by a click (menu bar, console back) rather than by hover. Pointer distance
    /// dismisses a panel you hovered open and walked away from; a clicked-open one is deliberate
    /// and its pointer is wherever the click was, so distance must not close it.
    private var stickyOpen = false
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
    private var hideTimer: Timer?

    /// Nothing is running, so there is nothing to show: the bar steps aside and hovering the
    /// notch brings it back. This used to be limited to screens with no notch, on the reasoning
    /// that a notch is dead pixels anyway — but the bar outgrew the notch, so at rest it sat on
    /// the menu bar with a stale number on it.
    private var autoHides: Bool { Prefs.shared.autoHideSeconds > 0 }

    /// The bar is out of the way: it stepped aside, or the user asked for quiet. Only ever true
    /// while collapsed — a panel opened deliberately is never hidden from the person opening it,
    /// which is also the only route back to settings to call the quiet off.
    var hushed: Bool { state == .collapsed && (autoHidden || Prefs.shared.snoozing) }

    /// A coarse identity for what the bar is currently saying, so the view can wake it when
    /// that changes without Island having to hear about every individual event.
    var stateTag: String {
        switch state {
        case .collapsed: return "collapsed"
        case .peek:      return "peek"
        case .approval:  return "approval"
        case .question:  return "question"
        case .console:   return "console"
        case .expanded:  return "expanded"
        }
    }

    /// Show the bar and restart its clock. Called on hover, and whenever what it says changes.
    /// Anything Quiet held back, now that Quiet is over. Whatever expired meanwhile is dropped
    /// by presentNext, so this never resurrects a card its agent has already given up on.
    func resumeFromQuiet() {
        guard !Prefs.shared.snoozing, state == .collapsed else { return }
        guard !queuedQuestions.isEmpty || !queuedApprovals.isEmpty else { return }
        presentNext()
    }

    func wake() {
        hideTimer?.invalidate()
        if autoHidden { withAnimation(Motion.content) { autoHidden = false } }
        guard autoHides else { return }
        hideTimer = Timer.scheduledTimer(withTimeInterval: Prefs.shared.autoHideSeconds,
                                         repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state == .collapsed, !self.revealed else { return }
                // Never while something is happening. The bar exists to show that an agent is
                // working; hiding it then removes the one thing it is for.
                guard self.store.workingCount == 0, self.store.waitingCount == 0,
                      self.store.blockedCount == 0 else { return }
                withAnimation(Motion.content) { self.autoHidden = true }
            }
        }
    }
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
        sensor.rect = { [weak self] in self?.hotRect ?? .zero }
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
        // Collapsed is the state it opens in, and collapsed swallows nothing. Without this the
        // panel accepts clicks across the top of the screen until the first poll tick says
        // otherwise — right after login, over whatever is up there.
        panel.ignoresMouseEvents = true
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
        Hotkeys.shared.bindLasting([
            (kVK_ANSI_K, Hotkeys.cmdOpt, { [weak self] in
                guard let self else { return }
                if case .console = self.state { self.closeConsole() }
                else if let s = self.leadSession { self.openConsole(s) }
            }),
            // Flipping materials without touching anything else is the only honest way to
            // compare them — same panel, same content, same instant.
            (kVK_ANSI_G, Hotkeys.cmdOpt, {
                withAnimation(Motion.quick) { Surfaces.shared.toggle() }
            }),
        ])

        // Mirroring, docking and resolution changes invalidate everything measureNotch read,
        // and `pinned` holds a screen that may no longer exist. Re-home from scratch.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.pinned = nil
                self.followActiveScreen()
                self.refreshHitRegion()
            }
        }

        sensor.rect = { [weak self] in self?.hotRect ?? .zero }
        sensor.install(on: screen, notchWidth: notchWidth, notchHeight: notchHeight)
        wake()
        sensor.onEnter = { [weak self] in
            guard let self else { return }
            // Reveal is instant (the 100ms affordance rule); expanding waits for intent.
            self.wake()
            withAnimation(Motion.quick) { self.revealed = true }
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
            withAnimation(Motion.content) { self.revealed = false }
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

    /// The width the collapsed bar is currently drawing. Asked of the bar itself, so what reveals
    /// the island cannot drift from what the user can see of it.
    private var barWidth: CGFloat {
        let quiet = store.workingCount == 0 && store.waitingCount == 0 && !revealed
        let bar = CollapsedView(store: store, status: status, notchWidth: notchWidth,
                                revealed: revealed, quiet: quiet)
        let w = CollapsedView.sides(revealed: revealed, left: bar.leftText, right: bar.rightText)
        return notchWidth + w.left + w.right + 2 * CollapsedView.notchMargin
    }

    /// The strip that reveals the island, and keeps it open once it is.
    ///
    /// Two different questions, so two widths. While the bar is hidden there is nothing to aim at
    /// but the notch, and a wide invisible strip is what made merely heading for a browser tab
    /// open the island. While it is on screen, anything narrower than the bar means hovering most
    /// of what you can see does nothing — which is just as broken, from the other end.
    private var hotRect: NSRect {
        guard let screen else { return .zero }
        let aim = HoverSensor.hotWidth(notchWidth: notchWidth)
        let w = hushed ? aim : max(aim, barWidth)
        // One point taller than the notch, and the point matters: CGRect.contains EXCLUDES its
        // max edge, and macOS pins the cursor to exactly screen.maxY when you push it to the top
        // — the most natural way to reach the bar. The pointer then sat one point outside the
        // strip and the island opened only if you stopped just short of the edge.
        return NSRect(x: screen.frame.midX - w / 2, y: screen.frame.maxY - notchHeight,
                      width: w, height: notchHeight + 1)
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
        // The card is drawn inside the panel, which is maxSize tall and never resized — so a
        // cap taken from the SCREEN described a card twice the size of the one on it, and this
        // size is also the click region: the island swallowed presses far below the card.
        let cap = Self.maxSize.height - notchHeight - Self.notchClearance - 6
        // An explanation is five lines and a rule; it scrolls with the options, so this only has
        // to make room for it, never to measure it exactly.
        let shown = explaining.contains(item.id) || explanations[item.id] != nil
        // A lead sentence, plus a line of its own under each option.
        let extra: CGFloat = shown ? 40 + CGFloat(item.options.prefix(4).count) * 30 : 0
        return CGSize(width: w, height: min(item.cardHeight(width: w) + extra, max(120, cap)))
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
        // the pointer. Collapsed, it accepts nothing at all: the bar is a readout, and anything
        // it swallowed up there would be a click the menu bar or a fullscreen tab strip never
        // got. The sensor above it declines hit-testing for the same reason.
        sensor.resize()   // the strip tracks the bar, whose width changes with what it says
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
            if stickyOpen { return }   // dismissed by a click outside or Esc, never by distance
            if panelRect.union(hotRect).insetBy(dx: -8, dy: -8).contains(mouse) {
                outsideTicks = 0
                return
            }
            outsideTicks += 1
            if outsideTicks >= 3 { outsideTicks = 0; collapse() }
        }
    }

    func expand(sticky: Bool = false) {
        guard state != .expanded else { return }
        stickyOpen = sticky
        if let v = window?.contentView { frames.start(on: v) }
        withAnimation(Motion.shell) { state = .expanded }
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

    /// Everything the expanded panel must release, whatever replaces it.
    private func tearDownPanel() {
        frames.stopAndReport()
        dwell?.cancel()
        // Quiet mode collapses straight out of a live card. Without these the card's chords stay
        // bound to a card nobody can see, and the panel keeps the key window — so the next
        // keystroke anywhere goes nowhere.
        Hotkeys.shared.unbind()
        endTyping()
        removeClickMonitors()
        outsideTicks = 0
        stickyOpen = false
        store.setPanelVisible(false)
    }

    func collapse() {
        guard state != .collapsed else { return }
        tearDownPanel()
        withAnimation(Motion.shell) { state = .collapsed }
        repoll()
        // Every other transition refreshes this; collapse did not. The panel therefore kept
        // accepting events across its whole frame until the next poll — up to 750ms — and
        // swallowed the pointer before the hover sensor beneath it could see it. That is
        // exactly why the first move to the notch did nothing and the second worked.
        refreshHitRegion()
        if !hotRect.contains(NSEvent.mouseLocation) {
            withAnimation(Motion.content) { revealed = false }
        }
    }

    func toggle() { state == .expanded ? collapse() : expand(sticky: true) }

    /// Drop a toast below the notch, hold, spring back. Never interrupts an open panel.
    func peek(_ payload: PeekPayload) {
        guard !Prefs.shared.snoozing else { return }
        followActiveScreen()
        guard state != .expanded, !showingCard else { return }
        if case .console = state { return }   // someone is reading; a toast loses their place
        peekWork?.cancel()
        withAnimation(Motion.shell) { state = .peek(payload) }
        refreshHitRegion()
        let work = DispatchWorkItem { [weak self] in
            guard let self, case .peek = self.state else { return }
            withAnimation(Motion.shell) { self.state = .collapsed }
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
        withAnimation(Motion.shell) { state = .collapsed }
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
                withAnimation(Motion.shell) {
                    self.approvalContext = ctx
                }
                self.refreshHitRegion()
            }
        }
    }

    /// An approval outranks a toast: a blocked tool is the most urgent thing on screen.
    func present(_ approval: Approval) {
        guard !Prefs.shared.snoozing else {
            if approval.deadline > Date(),
               !queuedApprovals.contains(where: { $0.id == approval.id }) {
                queuedApprovals.append(approval)
            }
            Diagnostics.log("approval \(approval.id): held for quiet")
            return
        }
        guard !showingCard else {
            if !queuedApprovals.contains(where: { $0.id == approval.id }) {
                queuedApprovals.append(approval)
            }
            return
        }
        followActiveScreen()
        peekWork?.cancel(); approvalWork?.cancel()
        hold.end(); approvalContext = nil
        // Putting the card on screen IS engagement. Without this mark the hook keeps only its
        // 19s base timeout, so a card you looked at for half a minute was answering a hook that
        // had already gone — the allow went nowhere and nothing said so. Holding it open costs
        // nothing: the hook has its own 5 minute ceiling, and the drop below releases the mark.
        hold.begin(id: approval.id)
        Hotkeys.shared.bind([
            (kVK_ANSI_A, Hotkeys.cmdOpt, { [weak self] in self?.answer(approval, allow: true) }),
            (kVK_ANSI_D, Hotkeys.cmdOpt, { [weak self] in self?.answer(approval, allow: false) }),
            (kVK_ANSI_E, Hotkeys.cmdOpt, { [weak self] in self?.expandApproval() }),
        ])
        withAnimation(Motion.shell) { state = .approval(approval) }
        refreshHitRegion()
        // Drop the card when the hook stops waiting, so a dead prompt can't linger.
        let work = DispatchWorkItem { [weak self] in
            guard let self, case .approval(let a) = self.state, a.id == approval.id else { return }
            self.hold.end(); self.approvalContext = nil
            Hotkeys.shared.unbind()
            self.presentNext()
        }
        approvalWork = work
        // The same window a question gets. The hook's own deadline is the 19s it would have
        // waited unheld; now that the card holds it open, the card is what decides.
        let window = max(approval.deadline.timeIntervalSinceNow, Island.graceSeconds)
        DispatchQueue.main.asyncAfter(deadline: .now() + window, execute: work)
    }

    /// A question outranks everything: an agent is blocked until it is answered.
    func ask(_ question: Question) {
        guard !Prefs.shared.snoozing else {
            if question.deadline > Date(),
               !queuedQuestions.contains(where: { $0.id == question.id }) {
                queuedQuestions.append(question)
            }
            Diagnostics.log("question \(question.id): held for quiet")
            return
        }
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
                Diagnostics.log("question \(question.id): queued behind \(q.id), "
                                + "which is on screen and not stale")
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
            explanations = [:]; explaining = []
            graceBase = Date()
        }
        endTyping()
        // Keys are bound per question as the sequence advances, so 1-4 always means "this
        // question's options" rather than a running index across the whole ask.
        bindKeys(question, step: questionStep)
        withAnimation(Motion.shell) { state = .question(question) }
        Diagnostics.log("question \(question.id): on screen")
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
        withAnimation(Motion.content) { state = .question(q) }
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
    /// True when the console replaced the expanded panel, so closing returns you to the list
    /// rather than dropping all the way to the bar.
    private(set) var consoleFromPanel = false

    func openConsole(_ session: String) {
        if case .console(let cur) = state, cur == session { closeConsole(); return }
        guard !session.isEmpty else { return }
        // A card owns teardown a glance must not skip — the approval hold file, the queue —
        // and something waiting on you outranks looking at something else anyway.
        switch state {
        case .approval, .question: return
        case .expanded: consoleFromPanel = true; tearDownPanel()
        default: consoleFromPanel = false
        }
        followActiveScreen()
        peekWork?.cancel()
        withAnimation(Motion.shell) { state = .console(session) }
        watchForOutsideClick()
        // Without this the hit region keeps polling at the collapsed 0.75s cadence, so the
        // first click into the console lands on the app behind it and reads as "dismiss".
        repoll()
        refreshHitRegion()
    }

    func closeConsole() {
        guard case .console = state else { return }
        stopWatchingClicks()
        // The composer may hold the key window. Leaving it held means every keystroke the user
        // makes next lands in a field that is no longer on screen.
        endTyping()
        // Dismiss means dismiss, for the outside click, the chord and the chord's tag alike.
        // Only the `‹ agents` control goes back to the list, via consoleBackToPanel().
        consoleFromPanel = false
        withAnimation(Motion.shell) { state = .collapsed }
        repoll()
        refreshHitRegion()
    }

    /// Back to the agent list, specifically — distinct from dismissing the console outright.
    func consoleBackToPanel() {
        guard case .console = state else { return }
        stopWatchingClicks()
        endTyping()
        consoleFromPanel = false
        expand(sticky: true)
    }

    /// The session a bare summon opens: whoever needs you, else whoever is working.
    /// Only Claude Code writes the transcripts Console reads, so a Codex or Cursor row would
    /// open a console that can only ever say "nothing recorded".
    var leadSession: String? {
        let readable = store.rows.filter { $0.agent.vendor == .claude }
        return (readable.first { $0.waiting } ?? readable.first { $0.isWorking }
            ?? readable.first)?.agent.sessionId
    }

    func handToChat(_ q: Question) {
        Diagnostics.log("question \(q.id): handed to the chat")
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
        if answeringId == id { answeringId = nil; picks = [:]; typed = [:]; questionStep = 0
                               explanations = [:]; explaining = [] }
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

    /// Explain the question on screen. The call takes about ten seconds, so it marks an
    /// interaction at both ends — the hook's grace is 60s of idle, and waiting for an
    /// explanation is not idling.
    func explain(_ q: Question, step: Int) {
        guard step < q.items.count else { return }
        let item = q.items[step]
        markInteraction(q.id)
        guard explanations[item.id] == nil, !explaining.contains(item.id) else { return }
        explaining.insert(item.id)
        // The grace is 60s of idle and an engine that has to fall through to the next one can
        // outlast that, so the wait is held open rather than merely bracketed: a question must
        // never reach the chat while its reader is waiting to be told what it means.
        explainHold?.invalidate()
        explainHold = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] t in
            Task { @MainActor in
                guard let self, self.explaining.contains(item.id) else { t.invalidate(); return }
                self.markInteraction(q.id)
            }
        }
        Explain.run(item: item, session: q.session, cwd: q.cwd) { [weak self] text in
            guard let self else { return }
            self.explainHold?.invalidate(); self.explainHold = nil
            self.explaining.remove(item.id)
            self.explanations[item.id] = text
            // 45s later this ask may be gone and another one up; its grace is not ours to slide.
            if case .question(let live) = self.state, live.id == q.id { self.markInteraction(q.id) }
        }
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
        window?.keyable = true
        window?.makeKeyAndOrderFront(nil)
    }

    func endTyping() {
        guard typingFor != nil else { return }
        typingFor = nil
        window?.keyable = false
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
        // The question card has always confirmed its answer was collected; the approval card
        // never did, so an allow that arrived after its hook had gone closed the card and left
        // the user believing the tool was running. The hook deletes the file the instant it
        // reads it, so a file still sitting there means nobody was listening.
        Approvals.wasRead(approval.id) { [weak self] read in
            guard let self, !read else { return }
            let name = self.store.name(for: approval.session) ?? "the agent"
            Diagnostics.log("approval \(approval.id): \(allow ? "allow" : "deny") arrived too "
                            + "late, the hook had gone")
            Notifier.notify(title: name,
                            body: "Too late — approve it in the terminal instead",
                            key: approval.session)
        }
        presentNext()
    }

    /// Clicking a toast jumps straight to the agent that raised it.
    func actOnPeek(_ payload: PeekPayload) {
        peekWork?.cancel()
        if let row = store.rows.first(where: { $0.agent.sessionId == payload.session }) {
            store.jump(row)
        }
        withAnimation(Motion.shell) { state = .collapsed }
    }
}

private struct RootView: View {
    @ObservedObject var island: Island
    @ObservedObject var store: AgentStore
    @ObservedObject var status: StatusStore
    @ObservedObject private var surfaces = Surfaces.shared
    @ObservedObject private var typefaces = Typefaces.shared
    // `hushed` reads Prefs, which nothing else here observes: without this the bar keeps
    // drawing after you ask for quiet, and never comes back when it lapses.
    @ObservedObject private var prefs = Prefs.shared


    /// What the bar is currently saying, coarsely. When this changes the bar has news, so it
    /// comes back up rather than staying hidden until the pointer happens to pass.
    private var wakeKey: String {
        "\(island.stateTag)|\(store.workingCount)|\(store.waitingCount)|\(store.blockedCount)"
    }

    /// Nothing running, nothing waiting, pointer elsewhere.
    private var quiet: Bool {
        store.workingCount == 0 && store.waitingCount == 0 && !island.revealed
    }

    private var shellWidth: CGFloat {
        switch island.state {
        case .collapsed:
            // Ask the bar itself what it will print, so the width and the text cannot disagree.
            let bar = CollapsedView(store: store, status: status, notchWidth: island.notchWidth,
                                    revealed: island.revealed, quiet: quiet)
            let w = CollapsedView.sides(revealed: island.revealed,
                                        left: bar.leftText, right: bar.rightText)
            return island.notchWidth + w.left + w.right + 2 * CollapsedView.notchMargin
        case .peek:      return 380
        case .approval(let a):  return (a.plan != nil || island.approvalContext != nil) ? 640 : 560
        case .question(let q): return island.questionSize(q).width
        case .console:   return Island.consoleSize.width
        case .expanded:  return PanelView.width
        }
    }
    /// The sides are deliberately unequal — a sentence on one, two percentages on the other — but
    /// the shell is centred in its window, so the gap it leaves drifts half that difference off
    /// the real notch and buries whatever sits first after it. Shift it back by exactly that.
    /// Mirroring the sides instead removes the drift but pays the sentence's width twice, which
    /// is what made the bar half a screen wide.
    private var shellOffsetX: CGFloat {
        guard island.state == .collapsed, island.notchWidth > 0 else { return 0 }
        let bar = CollapsedView(store: store, status: status, notchWidth: island.notchWidth,
                                revealed: island.revealed, quiet: quiet)
        let w = CollapsedView.sides(revealed: island.revealed,
                                    left: bar.leftText, right: bar.rightText)
        return (w.right - w.left) / 2
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
    /// Empty space each state leaves below its content, which is all the room the sleek
    /// edge fade is allowed to use.
    private var bottomInset: CGFloat {
        switch island.state {
        // Razor sides with a 20px smeared bottom reads as broken on a 37pt bar, and the
        // reference island is crisp here too — the dissolve belongs on the big panels.
        case .collapsed: return 0
        case .expanded:  return PanelView.listPadding
        default:         return 6
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
                IslandBackground(corner: corner, expanded: island.state == .expanded,
                                 inset: bottomInset)

                Group {
                switch island.state {
                case .collapsed:
                    CollapsedView(store: store, status: status, notchWidth: island.notchWidth,
                                  revealed: island.revealed, quiet: quiet)
                        .onAppear { island.wake() }
                        .onChange(of: wakeKey) { _, _ in island.wake() }
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
                        },
                        explanation: island.questionItem(q).flatMap {
                            island.explanations[$0.id] },
                        explaining: island.questionItem(q).map {
                            island.explaining.contains($0.id) } ?? false,
                        onExplain: { island.explain(q, step: island.questionStep) })
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
                                onClose: { island.closeConsole() },
                                onBack: island.consoleFromPanel
                                    ? { island.consoleBackToPanel() } : nil,
                                typingFor: island.typingFor,
                                onBeginType: { island.beginTyping("console:\(sid)") },
                                onEndType: { island.endTyping() })
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 6)
                case .expanded:
                    // Inset past the physical notch so text clears the camera, while the shape
                    // behind it still reaches the screen edge and reads as one piece with it.
                    PanelView(store: store, status: status)
                        .padding(.top, island.notchHeight + Island.notchClearance)
                }
                }
            }
            .frame(width: shellWidth, height: shellHeight)
            .offset(x: shellOffsetX)
            .contentShape(NotchShape(radius: corner))
            // The whole shell, not just its contents: fading the bar's text while the shape
            // kept painting left an opaque black block sitting on the tab strip.
            .opacity(island.hushed ? 0 : 1)

            Spacer(minLength: 0)
        }
        .frame(width: Island.maxSize.width, height: Island.maxSize.height, alignment: .top)
        // At the root: you ask for quiet from the open panel, where CollapsedView is not in
        // the tree, so this cannot live on the bar it acts upon.
        .onChange(of: prefs.snoozedUntil) { _, _ in
            if prefs.snoozing { island.collapse() } else { island.wake(); island.resumeFromQuiet() }
        }
        // Theme's tokens read Surfaces statically, which SwiftUI cannot see as a dependency:
        // views whose stored properties are unchanged keep the old palette. Rebinding identity
        // on the toggle rebuilds the subtree so every Theme read is re-evaluated.
        .id("\(surfaces.choice.rawValue)-\(typefaces.choice.rawValue)")
    }
}
