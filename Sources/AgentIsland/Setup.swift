import Foundation
import Security

/// First-run detection: the panel silently shows less until the hooks exist, and a person should
/// not need to know a script exists to fix that. Same machinery, one click.
enum Setup {
    /// Whether our hooks are wired into Claude Code's settings.
    /// True once our hooks are wired into any agent the user actually has. Asking only about
    /// Claude told a Codex-only or Cursor-only user their hooks were missing for ever, with a
    /// setup prompt that would never go away however many times they ran it.
    /// Whether this copy carries a real Developer ID signature rather than the ad-hoc one a
    /// local build gets. Ad-hoc is what makes Gatekeeper refuse a double-click, and it is worth
    /// saying so once instead of leaving someone wondering what they just let past.
    static var signedForDistribution: Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess,
              let code else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return false }
        // An ad-hoc signature has no certificate chain at all.
        return !((dict["certificates"] as? [Any])?.isEmpty ?? true)
    }

    static func hooksInstalled() -> Bool {
        // Not just "the word appears": a bundled install once registered fourteen entries
        // pointing at a directory that does not exist, and this said they were installed. A
        // hook that is not on disk is not installed, whatever the settings file claims.
        let settings = ["/.claude/settings.json", "/.codex/hooks.json", "/.cursor/hooks.json"]
        return settings.contains { file in
            guard let data = FileManager.default.contents(atPath: Home.path + file),
                  let text = String(data: data, encoding: .utf8) else { return false }
            for line in text.split(whereSeparator: \.isNewline) where line.contains("agentisland-") {
                for piece in line.split(whereSeparator: { $0 == "\"" || $0 == "'" })
                where piece.contains("agentisland-") {
                    let path = piece.trimmingCharacters(in: .whitespaces)
                    if FileManager.default.isExecutableFile(atPath: path) { return true }
                }
            }
            return false
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
