import AppKit
import UserNotifications

/// Desktop alerts for things that need you, but only when you are not already looking.
///
/// A notch toast is invisible if you are on another Space or a different app, which is exactly
/// when a blocked agent sits unnoticed for minutes.
enum Notifier {
    private static var lastSent: [String: Date] = [:]

    /// An approval alert used to be a statement with nothing to press. It says an agent needs
    /// permission, and the only sane reading of clicking it is "yes" — but clicking a plain
    /// notification just dismisses it, so people answered and nothing happened, twice over:
    /// once because the card had a 19s fuse, and once because the alert was never a question.
    static let approvalCategory = "agentisland.approval"
    private static let allowAction = "agentisland.allow"
    private static let denyAction = "agentisland.deny"

    /// Set by the island. Given an approval id and the answer, delivers it the same way the
    /// card does — including telling the user when it arrived too late.
    static var onDecision: ((String, Bool) -> Void)?

    private static let delegate = NotificationDelegate()

    /// Registered before the first alert, or the buttons do not appear on it.
    static func registerActions() {
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: approvalCategory,
                actions: [
                    UNNotificationAction(identifier: allowAction, title: "Allow",
                                         options: [.authenticationRequired]),
                    UNNotificationAction(identifier: denyAction, title: "Deny",
                                         options: [.destructive]),
                ],
                intentIdentifiers: [], options: [])
        ])
    }

    /// Routes a button press back to whoever owns the decision.
    private final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(_ center: UNUserNotificationCenter,
                                    didReceive response: UNNotificationResponse,
                                    withCompletionHandler done: @escaping () -> Void) {
            defer { done() }
            guard let id = response.notification.request.content
                    .userInfo["approval"] as? String else { return }
            switch response.actionIdentifier {
            case allowAction: Task { @MainActor in onDecision?(id, true) }
            case denyAction:  Task { @MainActor in onDecision?(id, false) }
            default: break     // tapping the body opens the app; it is not an answer
            }
        }
    }

    /// True when the user is plainly already watching the agent's terminal.
    static var userIsWatching: Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        let id = front.bundleIdentifier ?? ""
        return id.hasPrefix("dev.warp.Warp") || id == Bundle.main.bundleIdentifier
    }

    static func requestAuthorization() {
        registerActions()
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// `approval` turns the alert into a question with two buttons. Without it the alert is a
    /// statement, which is the right shape for "finished" but the wrong one for "needs you".
    static func notify(title: String, body: String, key: String, approval: String? = nil) {
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
            if let approval {
                content.categoryIdentifier = approvalCategory
                content.userInfo["approval"] = approval
            }
            center.add(UNNotificationRequest(identifier: UUID().uuidString,
                                             content: content, trigger: nil))
        }
    }
}
