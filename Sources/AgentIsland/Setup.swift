import Foundation

/// First-run detection: the panel silently shows less until the hooks exist, and a person should
/// not need to know a script exists to fix that. Same machinery, one click.
enum Setup {
    /// Whether our hooks are wired into Claude Code's settings.
    /// True once our hooks are wired into any agent the user actually has. Asking only about
    /// Claude told a Codex-only or Cursor-only user their hooks were missing for ever, with a
    /// setup prompt that would never go away however many times they ran it.
    static func hooksInstalled() -> Bool {
        let settings = ["/.claude/settings.json", "/.codex/hooks.json", "/.cursor/hooks.json"]
        return settings.contains { file in
            guard let data = FileManager.default.contents(atPath: Home.path + file),
                  let text = String(data: data, encoding: .utf8) else { return false }
            return text.contains("agentisland")
        }
    }

    /// The bundled installer — backup-first, append-only, idempotent — resolved the same way the
    /// remote probe is: from the app bundle, then the repo for development builds.
    static func installerPath() -> String? {
        for dir in [Bundle.main.resourcePath, Bundle.main.bundlePath as String?] {
            if let dir, FileManager.default.fileExists(atPath: dir + "/install-hooks.py") {
                return dir + "/install-hooks.py"
            }
        }
        let argv0 = CommandLine.arguments[0]
        let bin = (argv0 as NSString).isAbsolutePath ? argv0
            : FileManager.default.currentDirectoryPath + "/" + argv0
        let repo = (((bin as NSString).deletingLastPathComponent as NSString)
            .deletingLastPathComponent as NSString).deletingLastPathComponent
        let p = repo + "/scripts/install-hooks.py"
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }

    /// Runs the installer. User-initiated only — this is a click, never part of a refresh.
    static func install(done: @escaping (Bool) -> Void) {
        guard let script = installerPath() else { done(false); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let out = Shell.runSync("/usr/bin/python3", [script], timeout: 30)
            let ok = hooksInstalled()
            Diagnostics.log("hook setup: \(ok ? "installed" : "failed") \(out.prefix(120))")
            DispatchQueue.main.async { done(ok) }
        }
    }
}
