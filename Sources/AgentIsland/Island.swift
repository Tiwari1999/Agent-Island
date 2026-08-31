import AppKit
import Carbon.HIToolbox
import SwiftUI

private final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }
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
}

/// The window is created once at its maximum footprint and never resized — the window server
/// does not interpolate content across a live resize, which is what makes frame animation stutter.
@MainActor
final class Island: NSObject, ObservableObject {
    @Published var state: IslandState = .collapsed
    @Published var revealed = false
    @Published var notchWidth: CGFloat = 0
    @Published var notchHeight: CGFloat = 32

    static let maxSize = NSSize(width: 860, height: 420)
    /// Breathing room under the camera housing. Insetting content by exactly `notchHeight` left
    /// zero margin, so the first row of header text sat right against the bezel and read as
    /// clipped. safeAreaInsets is the logical inset, not the physical glass.
    static let notchClearance: CGFloat = 8

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
    private var hoverTicks = 0
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

        store.onBackgroundAttach = { [weak self] name in
            self?.peek(PeekPayload(session: "", title: name,
                                   message: "attach command copied — paste in the new tab",
                                   needsInput: false))
        }

        store.hooks.onApproval = { [weak self] approval in
            guard let self else { return }
            self.present(approval)
            let name = self.store.rows.first { $0.agent.sessionId == approval.session }?.displayName
                ?? "Agent"
            Notifier.notify(title: "\(name) needs permission",
                            body: "\(approval.tool): \(approval.detail)", key: approval.session)
        }

        store.hooks.onQuestion = { [weak self] question in
            guard let self else { return }
            self.ask(question)
            let name = self.store.rows.first { $0.agent.sessionId == question.session }?.displayName
                ?? "Agent"
            Notifier.notify(title: name, body: question.text, key: question.session)
        }

        store.hooks.onAttention = { [weak self] session, message, needsInput in
            guard let self else { return }
            let name = self.store.rows.first { $0.agent.sessionId == session }?.agent.label
                ?? String(session.prefix(8))
            self.peek(PeekPayload(session: session, title: name,
                                  message: needsInput ? message : "finished",
                                  needsInput: needsInput))
            if needsInput { Notifier.notify(title: name, body: message, key: session) }
        }

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
            guard self.state == .collapsed else { return }
            withAnimation(.easeOut(duration: 0.16)) { self.revealed = false }
        }

        poll = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.track() }
        }
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
        let w: CGFloat = 380, h = notchHeight + 44
        return NSRect(x: screen.frame.midX - w / 2, y: screen.frame.maxY - h, width: w, height: h)
    }

    /// The approval card is wider than a toast and must be fully clickable.
    private var approvalRect: NSRect {
        guard let screen else { return .zero }
        let w: CGFloat = 560, h = notchHeight + 54
        return NSRect(x: screen.frame.midX - w / 2, y: screen.frame.maxY - h, width: w, height: h)
    }

    /// Questions need room for the prompt plus a row of options.
    private var questionRect: NSRect {
        guard let screen else { return .zero }
        let w: CGFloat = 600, h = notchHeight + 108
        return NSRect(x: screen.frame.midX - w / 2, y: screen.frame.maxY - h, width: w, height: h)
    }

    /// Recompute which region accepts clicks. Called on every state change as well as on the
    /// poll, because waiting for the next tick left a window where clicks fell through the panel.
    private func refreshHitRegion() {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        var live = hotRect
        if state == .expanded { live = panelRect.union(hotRect) }
        if case .peek = state { live = peekRect.union(hotRect) }
        if case .approval = state { live = approvalRect.union(hotRect) }
        if case .question = state { live = questionRect.union(hotRect) }
        window.ignoresMouseEvents = !live.insetBy(dx: -4, dy: -4).contains(mouse)
    }

    private func track() {
        guard let window else { return }
        // Only re-home while collapsed; moving a visible panel would yank it mid-interaction.
        if state == .collapsed { followActiveScreen() }
        let mouse = NSEvent.mouseLocation
        var live = hotRect
        if state == .expanded { live = panelRect.union(hotRect) }
        if case .peek = state { live = peekRect.union(hotRect) }
        if case .approval = state { live = approvalRect.union(hotRect) }
        if case .question = state { live = questionRect.union(hotRect) }
        window.ignoresMouseEvents = !live.insetBy(dx: -4, dy: -4).contains(mouse)

        switch state {
        case .peek, .approval, .question:
            return   // hold until dwell elapses or the user answers; hover must not steal it
        case .collapsed:
            let inside = hotRect.contains(mouse)
            if revealed != inside {
                withAnimation(.easeOut(duration: 0.16)) { revealed = inside }
            }
            guard inside else { hoverTicks = 0; return }
            hoverTicks += 1
            if hoverTicks >= 2 { hoverTicks = 0; expand() }
        case .expanded:
            if live.insetBy(dx: -8, dy: -8).contains(mouse) { outsideTicks = 0; return }
            outsideTicks += 1
            if outsideTicks >= 3 { outsideTicks = 0; collapse() }
        }
    }

    func expand() {
        guard state != .expanded else { return }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) { state = .expanded }
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
            if self.panelRect.contains(NSEvent.mouseLocation) { return event }
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
        dwell?.cancel()
        removeClickMonitors()
        outsideTicks = 0; hoverTicks = 0
        withAnimation(.spring(response: 0.30, dampingFraction: 0.85)) { state = .collapsed }
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

    /// An approval outranks a toast: a blocked tool is the most urgent thing on screen.
    func present(_ approval: Approval) {
        followActiveScreen()
        peekWork?.cancel(); approvalWork?.cancel()
        Hotkeys.shared.bind([
            (kVK_ANSI_A, Hotkeys.cmdOpt, { [weak self] in self?.answer(approval, allow: true) }),
            (kVK_ANSI_D, Hotkeys.cmdOpt, { [weak self] in self?.answer(approval, allow: false) }),
        ])
        withAnimation(.spring(response: 0.34, dampingFraction: 0.80)) { state = .approval(approval) }
        refreshHitRegion()
        // Drop the card when the hook stops waiting, so a dead prompt can't linger.
        let work = DispatchWorkItem { [weak self] in
            guard let self, case .approval(let a) = self.state, a.id == approval.id else { return }
            Hotkeys.shared.unbind()
            withAnimation(.spring(response: 0.30, dampingFraction: 0.85)) { self.state = .collapsed }
        }
        approvalWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + approval.deadline.timeIntervalSinceNow,
                                      execute: work)
    }

    /// A question outranks everything: an agent is blocked until it is answered.
    func ask(_ question: Question) {
        followActiveScreen()
        peekWork?.cancel(); questionWork?.cancel()
        Hotkeys.shared.bind(question.options.prefix(4).enumerated().map { i, opt in
            (Hotkeys.digits[i], Hotkeys.cmdOpt, { [weak self] in self?.choose(question, option: opt) })
        })
        withAnimation(.spring(response: 0.34, dampingFraction: 0.80)) { state = .question(question) }
        refreshHitRegion()
        let work = DispatchWorkItem { [weak self] in
            guard let self, case .question(let q) = self.state, q.id == question.id else { return }
            Hotkeys.shared.unbind()
            withAnimation(.spring(response: 0.30, dampingFraction: 0.85)) { self.state = .collapsed }
        }
        questionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + question.deadline.timeIntervalSinceNow,
                                      execute: work)
    }

    func choose(_ question: Question, option: String) {
        questionWork?.cancel()
        Hotkeys.shared.unbind()
        Approvals.answer(question, choice: option)
        withAnimation(.spring(response: 0.30, dampingFraction: 0.85)) { state = .collapsed }
    }

    func answer(_ approval: Approval, allow: Bool) {
        approvalWork?.cancel()
        Hotkeys.shared.unbind()
        Approvals.decide(approval, allow: allow)
        withAnimation(.spring(response: 0.30, dampingFraction: 0.85)) { state = .collapsed }
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

    /// Visible on hover, while a toast shows, and whenever an agent is actually live —
    /// status you have to hunt for is not status.
    private var visible: Bool {
        if island.state == .expanded || island.revealed { return true }
        if case .peek = island.state { return true }
        if case .approval = island.state { return true }
        if case .question = island.state { return true }
        return store.workingCount > 0 || store.waitingCount > 0
    }

    private var shellWidth: CGFloat {
        switch island.state {
        case .collapsed:
            return island.notchWidth + 2 * (CollapsedView.sideWidth + CollapsedView.notchMargin)
        case .peek:      return 380
        case .approval:  return 560
        case .question:  return 600
        case .expanded:  return PanelView.width
        }
    }
    private var shellHeight: CGFloat {
        switch island.state {
        // 1mm (~3pt) shy of the notch so the rounded bottom stops clipping the window beneath.
        case .collapsed: return max(20, island.notchHeight - 3)
        case .peek:      return island.notchHeight + 44
        case .approval:  return island.notchHeight + 54
        case .question:  return island.notchHeight + 108
        case .expanded:  return PanelView.height
        }
    }
    private var corner: CGFloat {
        switch island.state {
        // 1mm (~3pt) shy of the notch so the rounded bottom stops clipping the window beneath.
        case .collapsed: return max(20, island.notchHeight - 3) * 0.55
        case .peek:      return 20
        case .approval:  return 22
        case .question:  return 22
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
                    CollapsedView(store: store, status: status, notchWidth: island.notchWidth)
                case .peek(let p):
                    PeekView(title: p.title, message: p.message,
                             needsInput: p.needsInput, notchWidth: island.notchWidth)
                        .contentShape(Rectangle())
                        .onTapGesture { island.actOnPeek(p) }
                case .approval(let a):
                    ApprovalCard(
                        approval: a,
                        agentName: store.rows.first { $0.agent.sessionId == a.session }?.agent.label
                            ?? String(a.session.prefix(8)),
                        onAllow: { island.answer(a, allow: true) },
                        onDeny:  { island.answer(a, allow: false) })
                        .padding(.top, island.notchWidth > 0 ? 8 : 0)
                case .question(let q):
                    QuestionCard(
                        question: q,
                        agentName: store.rows.first { $0.agent.sessionId == q.session }?.displayName
                            ?? "agent",
                        onChoose: { island.choose(q, option: $0) })
                        .padding(.top, island.notchWidth > 0 ? 8 : 0)
                case .expanded:
                    // Inset past the physical notch so text clears the camera, while the shape
                    // behind it still reaches the screen edge and reads as one piece with it.
                    PanelView(store: store, status: status)
                        .padding(.top, island.notchHeight + Island.notchClearance)
                }
            }
            .frame(width: shellWidth, height: shellHeight)
            .opacity(visible ? 1 : 0)
            .animation(.easeOut(duration: 0.16), value: visible)
            .contentShape(NotchShape(radius: corner))

            Spacer(minLength: 0)
        }
        .frame(width: Island.maxSize.width, height: Island.maxSize.height, alignment: .top)
    }
}
