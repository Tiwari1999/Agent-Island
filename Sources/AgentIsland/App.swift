import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = AgentStore()
    private let status = StatusStore()
    private var island: Island!
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ note: Notification) {
        store.start()
        status.start()
        Notifier.requestAuthorization()
        island = Island(store: store, status: status)
        island.install()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "circle.hexagongrid",
                                     accessibilityDescription: "AgentIsland")
        item.button?.target = self
        item.button?.action = #selector(toggle)
        statusItem = item
    }

    @objc private func toggle() { island.toggle() }
}

@main
@MainActor
struct AgentIslandApp {
    static func main() {
        // Pure text logic is worth checking without a window; the suite drives this.
        if CommandLine.arguments.contains("--check-prompts") { exit(PromptCheck.run()) }
        if CommandLine.arguments.contains("--costs-json") { print(Costs.json()); exit(0) }
        if CommandLine.arguments.contains("--check-proc") { exit(ProcCheck.run()) }
        // Dump one session's recent tool calls, so the parser can be asserted on real data.
        if let i = CommandLine.arguments.firstIndex(of: "--console"),
           let session = CommandLine.arguments.dropFirst(i + 1).first {
            let cwd = CommandLine.arguments.dropFirst(i + 2).first
            let t0 = Date()
            let feed = Console.recent(session: session, cwd: cwd)
            let ms = Date().timeIntervalSince(t0) * 1000
            let said = feed.filter(\.isSaid).count
            print(String(format: "%d entries (%d said, %d ran) in %.1f ms",
                         feed.count, said, feed.count - said, ms))
            var ordered = true
            var last: Date?
            for e in feed {
                if let a = last, let b = e.at, b < a { ordered = false }
                last = e.at ?? last
                switch e.kind {
                case .said(let t):
                    print("SAID " + t.replacingOccurrences(of: "\n", with: " ").prefix(88))
                case .ran(let tool, let why, let secs, let failed):
                    print("RAN  \(tool) · \(why.prefix(50)) · "
                          + (secs.map { String(format: "%.1fs", $0) } ?? "-")
                          + (failed ? " FAILED" : ""))
                }
            }
            print("chronological: \(ordered ? "yes" : "NO")")
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--tool-calls"),
           let session = CommandLine.arguments.dropFirst(i + 1).first {
            let cwd = CommandLine.arguments.dropFirst(i + 2).first
            for c in ToolCalls.recent(session: session, cwd: cwd, limit: 8) {
                let state = c.isError ? "ERR" : c.running ? "RUN" : "ok "
                print("\(state) \(c.tool.padding(toLength: min(14, max(c.tool.count, 14)), withPad: " ", startingAt: 0)) "
                      + "| \(c.duration ?? "-") | why=\(c.why.prefix(56))"
                      + (c.isAgent ? " | agent=\(c.subagentKind ?? "")" : "")
                      + "\n      out=\(c.response?.prefix(60) ?? "<none>")")
            }
            exit(0)
        }
        // Synchronous probe of one remote, for the suite: async polling can't be asserted on.
        if let i = CommandLine.arguments.firstIndex(of: "--probe-remote"),
           let host = CommandLine.arguments.dropFirst(i + 1).first {
            let agents = RemoteSource.probe(host: host)
            for a in agents {
                print("\(a.vendor.rawValue) \(a.sessionId) state=\(a.state ?? "-") "
                      + "title=\(a.titleOverride ?? "-")")
            }
            exit(agents.isEmpty ? 1 : 0)
        }
        // Discovery only, against whatever HOME points at, so a synthetic fleet can be measured
        // without a window and without touching the real panel.
        if let i = CommandLine.arguments.firstIndex(of: "--benchmark-discovery") {
            let runs = CommandLine.arguments.dropFirst(i + 1).first.flatMap(Int.init) ?? 3
            let sources: [AgentSource] = [ClaudeSource(), CodexSource(), CursorSource(),
                                          RemoteSource()]
            for run in 1...runs {
                var line = "run \(run):"
                var total = 0.0
                for src in sources where src.isAvailable {
                    let t = Date()
                    let n = src.discover().count
                    let dt = Date().timeIntervalSince(t)
                    total += dt
                    line += String(format: " %@ %d/%.3fs", src.vendor.rawValue, n, dt)
                }
                print(line + String(format: "  total %.3fs  %@", total, Shell.spawnsSinceLastCheck()))
            }
            exit(0)
        }

        // The routing harness drives the real row-click path for one process, so the hit rate it
        // measures is the app's own resolution and not a reimplementation of it.
        if let i = CommandLine.arguments.firstIndex(of: "--jump-pid"),
           let pid = CommandLine.arguments.dropFirst(i + 1).first.flatMap(Int.init) {
            ProcEnv.prime(pids: [pid])   // resolve() reads a cache the refresh normally fills
            let host = HostTerminal.resolve(pid: pid)
            print("host=\(host.name) precise=\(host.isPrecise) target=\(host.target ?? "-")")
            exit(host.jump() ? 0 : 1)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // menu-bar app: no Dock icon
        app.run()
        _ = delegate                          // keep the delegate alive for the app's lifetime
    }
}
