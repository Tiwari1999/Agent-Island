import AppKit

/// Where an agent is running, and the best available way to get back to it.
///
/// Agents are not only started in Warp — they run in Terminal, iTerm2, the VS Code and Cursor
/// integrated terminals, and JetBrains IDEs. Each exposes a different amount of control, so the
/// jump degrades honestly rather than pretending every host is equal.
enum HostTerminal: Equatable {
    /// A pane inside tmux. The outer app is carried so the jump can raise it too — selecting a
    /// pane in a terminal that is behind another window moves nothing the user can see.
    case tmux(pane: String, outerBundle: String?)
    case warp(focusURL: String)
    case iterm(session: String)
    case appleTerminal(session: String)
    case kitty(window: String)
    case wezterm(pane: String)
    /// Ghostty builds whose AppleScript `terminal` has a `tty` (after 1.3.1); older ones stay `.app`.
    case ghostty(tty: String)
    /// cmux's AppleScript `terminal` id, which it also puts in the shell as CMUX_SURFACE_ID.
    case cmux(surface: String)
    /// A VS Code or Cursor integrated terminal. `pids` is the agent and its ancestors, one of
    /// which is the shell the editor reports as that terminal's processId.
    case ide(scheme: String, bundleID: String, name: String, pids: [Int])
    case app(bundleID: String, name: String)   // best effort: raise the app
    /// The host is known to have per-session focus, but this session's handle is missing —
    /// a restored session, a re-parented shell, an ssh or tmux layer. Raising the app would
    /// land on whichever tab was last focused, which is worse than declining: the user
    /// believes they were taken somewhere and acts on the wrong session.
    case degraded(bundleID: String, name: String, reason: String)
    case unknown

    /// Friendly label for the row's chip.
    /// The app a keystroke would land in, when the island has to fall back to the keyboard
    /// because this host takes no input any other way. nil means do not post anything.
    var pasteTarget: String? {
        switch self {
        case .warp: return "dev.warp.Warp-Stable"
        // Only Warp. A bundle id names the app, not the session — pasting into Cursor, VS Code
        // or Ghostty lands in whatever document is frontmost, which is not where this belongs.
        case .ghostty, .cmux, .ide: return nil
        case .degraded, .app, .tmux, .iterm, .appleTerminal, .kitty, .wezterm, .unknown: return nil
        }
    }

    var name: String {
        switch self {
        case .tmux: return "tmux"
        case .warp: return "Warp"
        case .iterm: return "iTerm2"
        case .appleTerminal: return "Terminal"
        case .kitty: return "kitty"
        case .wezterm: return "WezTerm"
        case .ghostty: return "Ghostty"
        case .cmux: return "cmux"
        case .ide(_, _, let n, _): return n
        case .app(_, let n): return n
        case .degraded(_, let n, _): return n
        case .unknown: return "background"
        }
    }

    /// True when we can reach the exact tab/pane, not merely the application.
    /// The exact handle this jump will use, for harnesses that need to check where it aims.
    var target: String? {
        switch self {
        case .warp(let url):        return url
        case .iterm(let session):   return session
        case .cmux(let surface):    return surface
        case .ide:                  return ideURL
        default:                    return nil
        }
    }

    var isPrecise: Bool {
        switch self {
        case .tmux, .warp, .iterm, .appleTerminal, .kitty, .wezterm, .ghostty, .cmux: return true
        case .ide(let scheme, _, _, _): return Self.ideExtensionInstalled(scheme: scheme)
        case .app, .degraded, .unknown: return false
        }
    }

    /// Why a jump will not be precise, for the row's tooltip.
    var caveat: String? {
        switch self {
        case .app(_, let n): return "\(n) exposes no per-tab focus API"
        case .ide(let scheme, _, let n, _) where !Self.ideExtensionInstalled(scheme: scheme):
            return "window only \u{2014} install the AgentIsland extension in \(n) for the exact terminal"
        case .degraded(_, _, let r): return r
        case .unknown: return "not running under a known terminal"
        default: return nil
        }
    }

    var canReach: Bool { self != .unknown }

    static func resolve(pid: Int) -> HostTerminal {
        let i = ProcEnv.info(pid: pid)
        // MonoCode pipes its agents (no tty, no deep link) and leaks its launcher's TERM_PROGRAM: raise MonoCode.
        if i.uiDriven { return .app(bundleID: "com.monocode.desktop", name: "MonoCode") }
        // Its WARP_FOCUS_URL is the tab Claude was started from, so following it landed in someone else's chat.
        if i.claudeBackground { return .unknown }
        // TERM_PROGRAM names the terminal that actually owns this shell, and iTerm2/Terminal set
        // it reliably. Trust it before the bare Warp handle: opening iTerm2 from a Warp tab
        // leaks WARP_FOCUS_URL into it, and keying on that first sent the jump to Warp — the
        // wrong app. Warp itself often leaves TERM_PROGRAM empty, so it stays the fallback.
        // Ahead of the terminal checks: whatever draws the window, the pane is tmux's, and a
        // pane handle reaches sessions in terminals that publish no scripting interface at all.
        if let pane = i.tmuxPane, !pane.isEmpty { return .tmux(pane: pane, outerBundle: i.bundleID) }
        if i.termProgram == "iTerm.app", let s = i.itermSession { return .iterm(session: s) }
        if i.termProgram == "Apple_Terminal" {
            // TERM_SESSION_ID is a UUID Terminal never surfaces in its dictionary; the tty is the
            // only handle that focuses the right tab, so carry that instead.
            if let tty = i.tty { return .appleTerminal(session: tty) }
            return .degraded(bundleID: i.bundleID ?? "com.apple.Terminal", name: "Terminal",
                             reason: "no controlling tty — a restored session or a tmux/ssh layer")
        }
        // A background agent has no terminal of its own, so an inherited WARP_FOCUS_URL is not
        // evidence of a tab. Its owning interactive session does have one, and that is the
        // window the user is actually watching it in — resolve there instead of declining.
        if i.tty == nil {
            if let owner = Proc.ancestorWithTTY(pid: pid) { return resolve(pid: owner) }
            return .degraded(bundleID: i.bundleID ?? "dev.warp.Warp",
                             name: i.bundleID.map { friendly($0, i) } ?? "background",
                             reason: "background session \u{2014} no terminal anywhere above it")
        }
        // cmux says TERM_PROGRAM=ghostty and passes on its launcher's WARP_FOCUS_URL; its surface id is the tab.
        if i.bundleID == "com.cmuxterm.app", let s = i.cmuxSurface, !s.isEmpty { return .cmux(surface: s) }
        if let w = i.kittyWindow, !w.isEmpty { return .kitty(window: w) }
        if i.termProgram == "ghostty" || i.bundleID == "com.mitchellh.ghostty",
           let tty = i.tty, ghosttyHasTTY { return .ghostty(tty: tty) }
        // Before the Warp handle: an editor opened from a Warp tab inherits WARP_FOCUS_URL too.
        if let h = ide(termProgram: i.termProgram, bundleID: i.bundleID, pids: lineage(pid)) { return h }
        if let p = i.weztermPane, !p.isEmpty { return .wezterm(pane: p) }
        if let u = i.focusURL { return .warp(focusURL: u) }
        if let s = i.itermSession { return .iterm(session: s) }
        if let b = i.bundleID {
            // Warp does publish a per-session handle, so its absence means this session cannot
            // be resolved — not that Warp lacks the capability. Say so instead of guessing.
            if b.hasPrefix("dev.warp.Warp") {
                return .degraded(bundleID: b, name: "Warp",
                                 reason: "session handle missing — restored session, or a tmux/ssh layer")
            }
            return .app(bundleID: b, name: friendly(b, i))
        }
        if i.jetbrains { return .app(bundleID: "com.jetbrains", name: "JetBrains") }
        return .unknown
    }

    /// Pure, so `--check-host` can pin it without a live editor.
    static func ide(termProgram: String?, bundleID: String?, pids: [Int]) -> HostTerminal? {
        guard termProgram == "vscode", let b = bundleID, !pids.isEmpty else { return nil }
        if b == "com.microsoft.VSCode" { return .ide(scheme: "vscode", bundleID: b, name: "VS Code", pids: pids) }
        if b.contains("todesktop") { return .ide(scheme: "cursor", bundleID: b, name: "Cursor", pids: pids) }
        return nil
    }

    /// The agent and up to five ancestors, by syscall. The editor knows only its shell's pid,
    /// and an agent started through npx or a wrapper is not that shell's direct child.
    static func lineage(_ pid: Int) -> [Int] {
        var out = [pid]
        while out.count < 6, let p = Proc.parent(pid: out[out.count - 1]) { out.append(p) }
        return out
    }

    var ideURL: String? {
        guard case .ide(let scheme, _, _, let pids) = self else { return nil }
        return "\(scheme)://agentisland.ide-focus/focus?pid=" + pids.map(String.init).joined(separator: ",")
    }

    /// Read from the editor's own install list, re-read only when it changes; never spawns.
    static func ideExtensionInstalled(scheme: String) -> Bool {
        let path = NSHomeDirectory() + "/.\(scheme)/extensions/extensions.json"
        let stamp = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        extLock.lock(); defer { extLock.unlock() }
        if let hit = extCache[path], hit.stamp == stamp { return hit.ok }
        let ok = stamp != nil && ((try? String(contentsOfFile: path, encoding: .utf8))?
            .contains("\"agentisland.ide-focus\"") ?? false)
        extCache[path] = (stamp, ok)
        return ok
    }
    private static var extCache: [String: (stamp: Date?, ok: Bool)] = [:]
    private static let extLock = NSLock()

    /// Only Ghostty builds after 1.3.1 publish a terminal's tty to AppleScript; the sdef says which.
    static let ghosttyHasTTY: Bool = {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty"),
              let sdef = try? String(contentsOf: app.appendingPathComponent("Contents/Resources/Ghostty.sdef"),
                                     encoding: .utf8) else { return false }
        return sdef.contains("code=\"Gtty\"")
    }()

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
        case .tmux(let pane, let outer):
            let p = Self.tmuxSafe(pane)
            guard !p.isEmpty else { return false }
            // A pane id is server-unique, so one -t reaches the right window and pane; the
            // client may also be looking at a different session entirely.
            let ok = Shell.runSync("/bin/sh", ["-c",
                "tmux switch-client -t '\(p)' 2>/dev/null; "
                + "tmux select-window -t '\(p)' 2>/dev/null; "
                + "tmux select-pane -t '\(p)' 2>/dev/null && echo __ok__"]).contains("__ok__")
            if let outer { _ = activate(bundleID: outer) }
            return ok

        case .warp(let url):
            // open() answers whether a handler took the URL. Returning true regardless claimed
            // a landing even with Warp uninstalled, and the caller then skipped the fallback
            // that would have handed the user something they could use.
            guard let u = URL(string: url) else { return false }
            return NSWorkspace.shared.open(u)

        case .iterm(let session):
            // ITERM_SESSION_ID is "wNtNpN:UUID"; the scripting dictionary's `id of session` is
            // the bare UUID. Matching the whole env string never hit, so the jump silently did
            // nothing — the "doesn't work in iTerm2" report. Match on the UUID after the colon.
            let sid = Self.appleSafe(session.split(separator: ":").last.map(String.init) ?? session)
            guard !sid.isEmpty else { return false }
            return osascript("""
            tell application "iTerm"
              activate
              repeat with w in windows
                repeat with t in tabs of w
                  repeat with s in sessions of t
                    if id of s is "\(sid)" then
                      select w
                      select t
                      select s
                      return "1"
                    end if
                  end repeat
                end repeat
              end repeat
              return "0"
            end tell
            """)

        case .appleTerminal(let session):
            // `session` is the controlling tty ("/dev/ttysNNN"); Terminal exposes `tty of tab`,
            // so match the device name against it. TERM_SESSION_ID would never match — it is a
            // UUID Terminal does not surface.
            let tty = Self.appleSafe(session)
            guard !tty.isEmpty else { return false }
            return osascript("""
            tell application "Terminal"
              activate
              repeat with w in windows
                repeat with t in tabs of w
                  if tty of t is "\(tty)" then
                    set selected of t to true
                    set index of w to 1
                    return "1"
                  end if
                end repeat
              end repeat
              return "0"
            end tell
            """)

        case .kitty(let window):
            // KITTY_WINDOW_ID and WEZTERM_PANE are numbers out of the environment, and the
            // environment is not ours. Raising the app on a bad id is still the right outcome;
            // running whatever it contained is not.
            guard let id = Self.numericID(window) else { return false }
            // The focus result was discarded and the app raised regardless, so a window id that
            // no longer exists — or remote control switched off — reported a successful jump
            // while kitty came forward on whatever was already selected. runSync hands back
            // stdout and not a status, so the command says so itself.
            guard Self.succeeded("kitty @ focus-window --match id:\(id)") else { return false }
            return activate(bundleID: "net.kovidgoyal.kitty")

        case .wezterm(let pane):
            guard let id = Self.numericID(pane) else { return false }
            guard Self.succeeded("wezterm cli activate-pane --pane-id \(id)") else { return false }
            return activate(bundleID: "com.github.wez.wezterm")

        case .ghostty(let tty):
            let t = Self.appleSafe(tty)
            guard !t.isEmpty else { return false }
            return osascript("""
            tell application id "com.mitchellh.ghostty"
              repeat with t in terminals
                if tty of t is "\(t)" then
                  focus t
                  activate
                  return "1"
                end if
              end repeat
              return "0"
            end tell
            """)

        case .cmux(let surface):
            let s = Self.appleSafe(surface)
            // Not running means no session lives there, and `tell` would only launch it.
            guard !s.isEmpty, !NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.cmuxterm.app").isEmpty else { return false }
            // `focus` selects the terminal's workspace too, and brings its window forward.
            return osascript("""
            tell application id "com.cmuxterm.app"
              if not (exists terminal id "\(s)") then return "0"
              focus terminal id "\(s)"
              activate
              return "1"
            end tell
            """)

        case .ide(_, let bundle, let name, _):
            // Without the extension the URI would only raise an "unknown handler" prompt.
            if isPrecise, let s = ideURL, let u = URL(string: s), NSWorkspace.shared.open(u) {
                Diagnostics.log("jump -> \(name) terminal via \(s)")
                return true
            }
            return activate(bundleID: bundle)

        case .app(let bundle, _):
            // No tab-level API — raising the app is the honest ceiling here.
            return activate(bundleID: bundle)

        case .degraded:
            // Deliberately does nothing. The caller offers the working directory instead, so the
            // user can find the session themselves rather than trusting a wrong landing.
            return false

        case .unknown:
            return false
        }
    }

    /// Run a focus command and report whether it actually worked. `Shell.runSync` returns
    /// stdout rather than an exit status, so the shell reports the status as output.
    private static func succeeded(_ command: String) -> Bool {
        Shell.runSync("/bin/sh", ["-c", "\(command) >/dev/null 2>&1 && echo ok"], timeout: 4)
            .contains("ok")
    }

    private func activate(bundleID: String) -> Bool {
        let apps = NSWorkspace.shared.runningApplications.filter {
            ($0.bundleIdentifier ?? "").hasPrefix(bundleID)
        }
        guard let app = apps.first else { return false }
        app.activate(options: [.activateAllWindows])
        return true
    }

    /// A session handle comes from a process env var, which is attacker-influenceable in
    /// principle; it is interpolated into an AppleScript string, so strip it to the characters a
    /// real iTerm UUID or a tty path uses. Anything else yields "" and the jump declines.
    /// tmux ids carry a sigil — %pane, @window, $session — which appleSafe would strip, turning
    /// `-t %3` into `-t 3`: a different window, not that pane.
    static func tmuxSafe(_ s: String) -> String {
        String(s.unicodeScalars.filter {
            CharacterSet(charactersIn:
                "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_%@$").contains($0)
        }.prefix(64))
    }

    /// A terminal's own window/pane handle: digits only, which is what both kitty and WezTerm
    /// publish. Anything else came from somewhere we do not control.
    static func numericID(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        return !t.isEmpty && t.count <= 12 && t.allSatisfy(\.isNumber) ? t : nil
    }

    static func appleSafe(_ s: String) -> String {
        String(s.unicodeScalars.filter {
            CharacterSet(charactersIn:
                "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-/").contains($0)
        }.prefix(128))
    }

    /// Runs the script and believes what it RETURNS, not merely that it ran. A jump script
    /// that matches nothing still succeeds as a script; reporting that as a jump told the user
    /// the island had focused a tab it never found.
    private func osascript(_ source: String) -> Bool {
        var error: NSDictionary?
        let out = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { Diagnostics.log("osascript failed: \(error)") ; return false }
        // Scripts that answer "1"/"0" are jumps; the rest only had to run.
        guard let answer = out?.stringValue, answer == "0" || answer == "1" else { return true }
        if answer == "0" { Diagnostics.log("jump: no matching tab") }
        return answer == "1"
    }
}

/// `--check-host`: pins the IDE resolver to fixed inputs, since a live editor is not always open.
enum HostCheck {
    static func run() -> Int32 {
        var failed = 0
        func expect(_ ok: Bool, _ m: String) {
            if !ok { failed += 1; FileHandle.standardError.write("FAIL \(m)\n".data(using: .utf8)!) }
        }
        let code = HostTerminal.ide(termProgram: "vscode", bundleID: "com.microsoft.VSCode", pids: [92173, 91877])
        expect(code?.ideURL == "vscode://agentisland.ide-focus/focus?pid=92173,91877", "VS Code URL: \(String(describing: code?.ideURL))")
        expect(code?.name == "VS Code", "VS Code name")
        let cur = HostTerminal.ide(termProgram: "vscode", bundleID: "com.todesktop.230313mzl4w4u92", pids: [7])
        expect(cur?.ideURL == "cursor://agentisland.ide-focus/focus?pid=7" && cur?.name == "Cursor", "Cursor")
        expect(HostTerminal.ide(termProgram: nil, bundleID: "com.microsoft.VSCode", pids: [7]) == nil,
               "no TERM_PROGRAM=vscode is not an IDE terminal")
        expect(HostTerminal.ide(termProgram: "vscode", bundleID: "com.example.fork", pids: [7]) == nil,
               "an unknown fork has no known URI scheme")
        expect(HostTerminal.ide(termProgram: "vscode", bundleID: "com.microsoft.VSCode", pids: []) == nil,
               "no pids, nothing to match")
        let none = HostTerminal.ide(scheme: "no-such-editor", bundleID: "x", name: "X", pids: [7])
        expect(!none.isPrecise && none.caveat != nil, "without the extension the jump is window-only and says so")
        let me = Int(getpid())
        expect(Array(HostTerminal.lineage(me).prefix(2)) == [me, Int(getppid())], "lineage starts self, parent")
        print("host checks: \(failed == 0 ? "ok" : "\(failed) failed")")
        return failed == 0 ? 0 : 1
    }
}
