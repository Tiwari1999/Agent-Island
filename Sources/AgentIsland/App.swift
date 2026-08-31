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
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // menu-bar app: no Dock icon
        app.run()
        _ = delegate                          // keep the delegate alive for the app's lifetime
    }
}
