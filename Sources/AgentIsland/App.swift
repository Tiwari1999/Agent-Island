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
