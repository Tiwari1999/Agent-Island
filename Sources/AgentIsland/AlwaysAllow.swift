import Foundation

/// The auto-approve rule an "Always allow" click would save. Built only by `AlwaysAllow.rule`.
struct AlwaysRule: Equatable {
    let tool: String
    let pattern: String
    let cwd: String?

    /// The exact rule, as the card shows it before anyone commits to it.
    var preview: String {
        let place = cwd.map { " in " + ($0 as NSString).lastPathComponent } ?? ""
        return "\(tool) \(pattern)\(place)"
    }

    var json: [String: Any] {
        var d: [String: Any] = ["tool": tool, "pattern": pattern, "action": "allow"]
        if let cwd { d["cwd"] = cwd }
        return d
    }
}

/// Derives a narrow rule from one request, or refuses. Pure text: no subprocess, no I/O but `save`.
enum AlwaysAllow {
    static let rulesPath = ProcessInfo.processInfo.environment["AGENTISLAND_RULES"]
        ?? (NSHomeDirectory() as NSString).appendingPathComponent(".agentisland/rules.json")

    // Arguments may be plain words, paths, flags and quoted text, nothing a shell would act on:
    // a whitelist, so a metacharacter nobody thought of is refused rather than allowed.
    static let argTail = #"(?: [-\w./:=@,+%'"]*)*$"#

    // Copied verbatim from NEVER_AUTO in hooks/agentisland-rules.py; the suite checks they agree.
    // The hook would refuse these anyway, so offering to save one would be a promise it breaks.
    static let neverAuto = [
        #"\brm\s+(-\w*[rf]\w*\s+)+"#,
        #"\bsudo\b"#, #"\bdoas\b"#,
        #"--force\b"#, #"\s-f\b"#,
        #"\bgit\s+push\b"#, #"\bgit\s+reset\s+--hard\b"#, #"\bgit\s+clean\b"#,
        #"\bdrop\s+(table|database)\b"#, #"\btruncate\b"#, #"\bdelete\s+from\b"#,
        #"\bkubectl\s+delete\b"#, #"\bterraform\s+destroy\b"#,
        #">\s*/dev/"#, #"\bchmod\s+[0-7]*777\b"#, #":\(\)\{"#,
        #"\bmkfs\b"#, #"\bdd\b"#, #"\bfind\b.*-delete\b"#,
        #"\bcurl\b"#, #"\bwget\b"#, #"\bnc\b"#, #"\bshutdown\b"#, #"\breboot\b"#,
        #"\bdiskutil\b"#, #"\blaunchctl\b"#, #"\bcsrutil\b"#, #"\btccutil\b"#,
        #"\bosascript\b"#, #"\bsystemsetup\b"#, #"\bspctl\b"#,
    ]

    // Programs that run other code, destroy, escalate or reach the network: one approval of
    // these is never evidence that the next one is safe.
    static let refusedPrograms: Set<String> = [
        "sudo", "doas", "su", "env", "xargs", "exec", "eval", "command", "builtin", "nohup",
        "time", "timeout", "watch", "nice", "sh", "bash", "zsh", "fish", "dash", "ksh",
        "python", "python3", "node", "ruby", "perl", "php", "lua", "deno", "bun", "bunx",
        "npx", "osascript", "awk", "gawk", "sed", "find", "rm", "rmdir", "mv", "dd", "mkfs",
        "chmod", "chown", "chgrp", "chflags", "kill", "killall", "pkill", "shutdown", "reboot",
        "halt", "curl", "wget", "nc", "ncat", "telnet", "ssh", "scp", "sftp", "ftp", "rsync",
        "open", "launchctl", "defaults", "security", "diskutil", "csrutil", "tccutil",
        "systemsetup", "spctl", "crontab", "at", "truncate", "shred", "srm", "tee", "source",
    ]
    // These take a subcommand, and the subcommand is the part that says what will happen.
    static let subcommandPrograms: Set<String> = [
        "git", "npm", "yarn", "pnpm", "cargo", "go", "docker", "kubectl", "brew", "pip", "pip3",
        "swift", "gh", "terraform", "helm", "gcloud", "aws", "uv", "poetry", "bundle", "just",
    ]
    static let refusedSubcommands: Set<String> = [
        "push", "reset", "clean", "checkout", "restore", "rebase", "filter-branch", "update-ref",
        "delete", "destroy", "apply", "publish", "uninstall", "remove", "rm", "rmi", "prune",
        "kill", "drop", "exec", "x", "dlx", "eval", "ssh", "login", "logout", "auth",
    ]
    // `npm run X` runs whatever X is, so the rule names the script, not just "run".
    static let scriptSubcommands: Set<String> = ["run", "run-script"]

    static func rule(tool: String, input: [String: Any]?, cwd: String?) -> AlwaysRule? {
        guard let input else { return nil }
        let dir = cwd.flatMap { $0.hasPrefix("/") ? ($0.count > 1 && $0.hasSuffix("/") ? String($0.dropLast()) : $0) : nil }
        switch tool {
        case "Bash": return (input["command"] as? String).flatMap { bash($0, cwd: dir) }
        case "Edit", "Write", "Read": return (input["file_path"] as? String).flatMap { file(tool, $0, cwd: dir) }
        default: return nil
        }
    }

    static func bash(_ command: String, cwd: String?) -> AlwaysRule? {
        let lower = command.lowercased()
        if neverAuto.contains(where: { lower.range(of: $0, options: .regularExpression) != nil }) { return nil }
        let tokens = command.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard let prog = tokens.first, bare(prog, #"^[A-Za-z0-9][A-Za-z0-9._+-]*$"#),
              !refusedPrograms.contains(prog), !prog.hasPrefix("python") else { return nil }
        var head = [prog]
        if subcommandPrograms.contains(prog) {
            guard tokens.count > 1, bare(tokens[1], #"^[a-z][a-z0-9-]*$"#),
                  !refusedSubcommands.contains(tokens[1]) else { return nil }
            head.append(tokens[1])
            if scriptSubcommands.contains(tokens[1]) {
                guard tokens.count > 2, bare(tokens[2], #"^[A-Za-z0-9][A-Za-z0-9:._-]*$"#) else { return nil }
                head.append(tokens[2])
            }
        }
        let pattern = "^" + head.map(escape).joined(separator: " ") + argTail
        // The rule must cover the request it came from; a command it cannot match carries
        // something outside the whitelist, which is exactly a command not to save.
        guard command.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return AlwaysRule(tool: "Bash", pattern: pattern, cwd: cwd)
    }

    /// Files beside this one, inside the session's project and outside any hidden directory —
    /// `.git/hooks` or `.claude/settings.json` is a way to run code, not an edit.
    static func file(_ tool: String, _ path: String, cwd: String?) -> AlwaysRule? {
        guard let cwd, path.hasPrefix(cwd + "/"), !path.contains("\n") else { return nil }
        let parts = path.dropFirst(cwd.count + 1).split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") }) else { return nil }
        let parent = (path as NSString).deletingLastPathComponent
        return AlwaysRule(tool: tool, pattern: "^" + escape(parent) + #"/[^/.][^/\n]*$"#, cwd: cwd)
    }

    static func escape(_ s: String) -> String {
        var out = ""
        for c in s {
            if #"\.^$*+?()[]{}|"#.contains(c) { out.append("\\") }
            out.append(c)
        }
        return out
    }

    private static func bare(_ s: String, _ re: String) -> Bool {
        s.range(of: re, options: .regularExpression) != nil
    }

    enum Saved: Equatable { case added, exists, refused(String) }

    /// Written only on click, atomically, and never through a file the hook would itself ignore.
    static func save(_ rule: AlwaysRule, to path: String = rulesPath) -> Saved {
        let fm = FileManager.default
        let dir = (path as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        var rules: [Any] = []
        var st = stat()
        if lstat(path, &st) == 0 {
            // A file the hook refuses must not be quietly made acceptable by our rewrite.
            guard st.st_mode & S_IFMT == S_IFREG, st.st_uid == getuid(),
                  st.st_mode & (S_IWGRP | S_IWOTH) == 0 else { return .refused("rules file is not safely yours") }
            guard let data = fm.contents(atPath: path),
                  let list = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
                return .refused("rules file is not a JSON list; left untouched")
            }
            rules = list
        }
        let new = rule.json
        if rules.contains(where: { ($0 as? NSDictionary)?.isEqual(to: new) ?? false }) { return .exists }
        rules.append(new)
        guard let out = try? JSONSerialization.data(withJSONObject: rules,
                                                    options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return .refused("could not encode") }
        let part = path + ".\(getpid()).part"
        guard fm.createFile(atPath: part, contents: out, attributes: [.posixPermissions: 0o600]) else {
            return .refused("could not write \(dir)")
        }
        guard rename(part, path) == 0 else {
            try? fm.removeItem(atPath: part)
            return .refused("could not replace \(path)")
        }
        return .added
    }
}
