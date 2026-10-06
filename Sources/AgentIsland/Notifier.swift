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
    /// A click on the alert itself, with the session it is about.
    static var onOpen: ((String) -> Void)?

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
            let info = response.notification.request.content.userInfo
            switch (response.actionIdentifier, info["approval"] as? String) {
            case (allowAction, let id?): Task { @MainActor in onDecision?(id, true) }
            case (denyAction, let id?):  Task { @MainActor in onDecision?(id, false) }
            // The app has no window, so "opening" it showed nothing: go to the agent instead.
            case (UNNotificationDefaultActionIdentifier, _):
                if let s = info["session"] as? String { Task { @MainActor in onOpen?(s) } }
            default: break
            }
        }
    }

    /// True when the user is plainly already watching the agent's terminal.
    static var userIsWatching: Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        let id = front.bundleIdentifier ?? ""
        return id.hasPrefix("dev.warp.Warp") || id == Bundle.main.bundleIdentifier
    }

    /// What the system will actually do with an alert, as opposed to whether we once asked.
    /// notify() returns silently unless this is .on, so a welcome screen reporting "asked"
    /// while the grant was denied is a UI that says everything is fine and delivers nothing.
    enum Grant { case unasked, on, blocked }

    static func grant(_ done: @escaping (Grant) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { s in
            let g: Grant
            switch s.authorizationStatus {
            case .authorized, .provisional, .ephemeral: g = .on
            case .denied:                               g = .blocked
            default:                                    g = .unasked
            }
            DispatchQueue.main.async { done(g) }
        }
    }

    /// macOS only ever prompts once. After a denial the request returns immediately with no
    /// dialog, so the only way back is System Settings — which is why the caller needs this.
    static func openSettings() {
        guard let u = URL(string:
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        NSWorkspace.shared.open(u)
    }

    static func requestAuthorization(_ done: ((Grant) -> Void)? = nil) {
        registerActions()
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in
                guard let done else { return }
                grant(done)
            }
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
            // The island already plays one cue for this; two sounds for one event reads as
            // a bug. Whichever surface the user is looking at, they hear it once.
            content.sound = Prefs.shared.soundNeedsYou ? nil : .default
            content.userInfo["session"] = String(key.split(separator: "/").first ?? Substring(key))
            if let approval {
                content.categoryIdentifier = approvalCategory
                content.userInfo["approval"] = approval
            }
            center.add(UNNotificationRequest(identifier: UUID().uuidString,
                                             content: content, trigger: nil))
        }
    }
}
