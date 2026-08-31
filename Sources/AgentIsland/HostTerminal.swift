import AppKit

/// Where an agent is running, and the best available way to get back to it.
///
/// Agents are not only started in Warp — they run in Terminal, iTerm2, the VS Code and Cursor
/// integrated terminals, and JetBrains IDEs. Each exposes a different amount of control, so the
/// jump degrades honestly rather than pretending every host is equal.
enum HostTerminal: Equatable {
    case warp(focusURL: String)
    case iterm(session: String)
    case appleTerminal(session: String)
    case kitty(window: String)
    case wezterm(pane: String)
    case app(bundleID: String, name: String)   // best effort: raise the app
    case unknown

    /// Friendly label for the row's chip.
    var name: String {
        switch self {
        case .warp: return "Warp"
        case .iterm: return "iTerm2"
        case .appleTerminal: return "Terminal"
        case .kitty: return "kitty"
        case .wezterm: return "WezTerm"
        case .app(_, let n): return n
        case .unknown: return "background"
        }
    }

    /// True when we can reach the exact tab/pane, not merely the application.
    var isPrecise: Bool {
        switch self {
        case .warp, .iterm, .appleTerminal, .kitty, .wezterm: return true
        case .app, .unknown: return false
        }
    }

    var canReach: Bool {
        if case .unknown = self { return false }
        return true
    }

    static func resolve(pid: Int) -> HostTerminal {
        let i = ProcEnv.info(pid: pid)
        if let u = i.focusURL { return .warp(focusURL: u) }
        if let s = i.itermSession { return .iterm(session: s) }
        if let w = i.kittyWindow { return .kitty(window: w) }
        if let p = i.weztermPane { return .wezterm(pane: p) }
        // Terminal.app also sets TERM_SESSION_ID, so only claim it when it really is Terminal.
        if let s = i.appleSession, i.termProgram == "Apple_Terminal" { return .appleTerminal(session: s) }
        if let b = i.bundleID { return .app(bundleID: b, name: friendly(b, i)) }
        if i.jetbrains { return .app(bundleID: "com.jetbrains", name: "JetBrains") }
        return .unknown
    }

    /// Bundle ids are stable; product names are not, so map the ones worth naming and fall back
    /// to the last path component of the id.
    private static func friendly(_ bundle: String, _ i: ProcEnv.Info) -> String {
        switch bundle {
        case let b where b.hasPrefix("dev.warp.Warp"):     return "Warp"
        case "com.googlecode.iterm2":                      return "iTerm2"
        case "com.apple.Terminal":                         return "Terminal"
        case "com.microsoft.VSCode", "com.visualstudio.code.oss": return "VS Code"
        case let b where b.contains("todesktop"):          return "Cursor"
        case let b where b.hasPrefix("com.jetbrains.pycharm"): return "PyCharm"
        case let b where b.hasPrefix("com.jetbrains.goland"):   return "GoLand"
        case let b where b.hasPrefix("com.jetbrains.intellij"): return "IntelliJ"
        case let b where b.hasPrefix("com.jetbrains"):     return "JetBrains"
        case "com.mitchellh.ghostty":                      return "Ghostty"
        case "com.github.wez.wezterm":                     return "WezTerm"
        case "net.kovidgoyal.kitty":                       return "kitty"
        default:
            if let t = i.termProgram, !t.isEmpty { return t }
            return bundle.split(separator: ".").last.map(String.init) ?? "terminal"
        }
    }

    /// Focus the agent's session. Returns false when nothing could be done.
    @discardableResult
    func jump() -> Bool {
        switch self {
        case .warp(let url):
            guard let u = URL(string: url) else { return false }
            NSWorkspace.shared.open(u)
            return true

        case .iterm(let session):
            // iTerm2 publishes a real scripting dictionary, so the exact session can be selected.
            return osascript("""
            tell application "iTerm2"
              activate
              repeat with w in windows
                repeat with t in tabs of w
                  repeat with s in sessions of t
                    if id of s is "\(session)" then
                      select w
                      select t
                      select s
                      return
                    end if
                  end repeat
                end repeat
              end repeat
            end tell
            """)

        case .appleTerminal(let session):
            // Terminal.app has no session id in its dictionary; match on the tty it reports.
            let tty = session.split(separator: ":").last.map(String.init) ?? session
            return osascript("""
            tell application "Terminal"
              activate
              repeat with w in windows
                repeat with t in tabs of w
                  if tty of t contains "\(tty)" then
                    set selected of t to true
                    set index of w to 1
                    return
                  end if
                end repeat
              end repeat
            end tell
            """)

        case .kitty(let window):
            _ = Shell.runSync("/bin/sh", ["-c",
                "kitty @ focus-window --match id:\(window) 2>/dev/null"])
            return activate(bundleID: "net.kovidgoyal.kitty")

        case .wezterm(let pane):
            _ = Shell.runSync("/bin/sh", ["-c",
                "wezterm cli activate-pane --pane-id \(pane) 2>/dev/null"])
            return activate(bundleID: "com.github.wez.wezterm")

        case .app(let bundle, _):
            // No tab-level API — raising the app is the honest ceiling here.
            return activate(bundleID: bundle)

        case .unknown:
            return false
        }
    }

    private func activate(bundleID: String) -> Bool {
        let apps = NSWorkspace.shared.runningApplications.filter {
            ($0.bundleIdentifier ?? "").hasPrefix(bundleID)
        }
        guard let app = apps.first else { return false }
        app.activate(options: [.activateAllWindows])
        return true
    }

    private func osascript(_ source: String) -> Bool {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { Diagnostics.log("osascript failed: \(error)") ; return false }
        return true
    }
}
