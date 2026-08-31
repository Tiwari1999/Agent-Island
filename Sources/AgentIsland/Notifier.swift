import AppKit
import UserNotifications

/// Desktop alerts for things that need you, but only when you are not already looking.
///
/// A notch toast is invisible if you are on another Space or a different app, which is exactly
/// when a blocked agent sits unnoticed for minutes.
enum Notifier {
    private static var authorized: Bool?
    private static var lastSent: [String: Date] = [:]

    /// True when the user is plainly already watching the agent's terminal.
    static var userIsWatching: Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        let id = front.bundleIdentifier ?? ""
        return id.hasPrefix("dev.warp.Warp") || id == Bundle.main.bundleIdentifier
    }

    static func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { granted, _ in
                authorized = granted
            }
    }

    static func notify(title: String, body: String, key: String) {
        guard !userIsWatching else { return }
        // One alert per agent per minute; a chatty session must not become a pager.
        if let at = lastSent[key], Date().timeIntervalSince(at) < 60 { return }
        lastSent[key] = Date()

        if authorized == true {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        } else {
            // Ad-hoc signed builds are often refused by UNUserNotificationCenter; this path
            // always works and keeps the feature honest rather than silently dead.
            fallback(title: title, body: body)
        }
    }

    private static func fallback(title: String, body: String) {
        let esc = { (s: String) in s.replacingOccurrences(of: "\"", with: "\\\"") }
        let script = "display notification \"\(esc(body))\" with title \"\(esc(title))\""
        DispatchQueue.global(qos: .utility).async {
            let t = Process()
            t.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            t.arguments = ["-e", script]
            try? t.run()
        }
    }
}
