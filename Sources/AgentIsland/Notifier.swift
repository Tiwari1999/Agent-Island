import AppKit
import UserNotifications

/// Desktop alerts for things that need you, but only when you are not already looking.
///
/// A notch toast is invisible if you are on another Space or a different app, which is exactly
/// when a blocked agent sits unnoticed for minutes.
enum Notifier {
    private static var lastSent: [String: Date] = [:]

    /// True when the user is plainly already watching the agent's terminal.
    static var userIsWatching: Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        let id = front.bundleIdentifier ?? ""
        return id.hasPrefix("dev.warp.Warp") || id == Bundle.main.bundleIdentifier
    }

    static func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notify(title: String, body: String, key: String) {
        guard !userIsWatching else { return }
        // One alert per agent per minute; a chatty session must not become a pager.
        if let at = lastSent[key], Date().timeIntervalSince(at) < 60 { return }
        lastSent[key] = Date()

        // Only ever the app's own notification channel. The old osascript fallback posted via
        // `display notification`, which macOS brands as "Script Editor" — a stray, wrong-looking
        // alert. Gate on the live authorization so an unauthorized build stays silent rather
        // than borrowing another app's identity; grant AgentIsland in System Settings to see
        // these.
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            center.add(UNNotificationRequest(identifier: UUID().uuidString,
                                             content: content, trigger: nil))
        }
    }
}
