// Cases for the "Always allow" rule. NOT run on its own: tests/selftest.py lifts the real
// AlwaysAllow.swift out of the app, appends this file, and sets AGENTISLAND_RULES to a temp file.
import Foundation

var fails = 0
func check(_ n: String, _ ok: Bool) { if !ok { print("FAIL \(n)"); fails += 1 } }
func bash(_ c: String, cwd: String? = "/tmp/proj") -> AlwaysRule? {
    AlwaysAllow.rule(tool: "Bash", input: ["command": c], cwd: cwd)
}
func matches(_ r: AlwaysRule?, _ s: String) -> Bool {
    guard let r else { return false }
    return s.range(of: r.pattern, options: .regularExpression) != nil
}
let tail = AlwaysAllow.argTail

// Narrow rules for the commands people actually approve over and over.
check("git status names program and subcommand", bash("git status")?.pattern == "^git status" + tail)
check("git diff keeps its subcommand, not its args", bash("git diff --stat HEAD")?.pattern == "^git diff" + tail)
check("npm run names the script it runs", bash("npm run build")?.pattern == "^npm run build" + tail)
check("swift build", bash("swift build -c release")?.pattern == "^swift build" + tail)
check("a plain program is the program alone", bash("ls -la src")?.pattern == "^ls" + tail)
check("the rule is scoped to the session's project", bash("git status")?.cwd == "/tmp/proj")
check("a trailing slash on cwd is folded", bash("git status", cwd: "/tmp/proj/")?.cwd == "/tmp/proj")
let gs = bash("git status")
check("it matches its own request", matches(gs, "git status"))
check("and the same kind with other args", matches(gs, "git status -s --branch"))
check("but not a chained command", !matches(gs, "git status; rm -rf ~") && !matches(gs, "git status && x")
      && !matches(gs, "git status ;ls") && !matches(gs, "git status x;ls"))
check("nor a pipe, redirect or substitution", !matches(gs, "git status | sh")
      && !matches(gs, "git status > /etc/x") && !matches(gs, "git status $(id)")
      && !matches(gs, "git status `id`"))
check("nor a longer program name", !matches(gs, "git statusx") && !matches(gs, "git stash"))
check("nor a second line", !matches(gs, "git status\nrm -rf ~"))
check("never a catch-all", !matches(gs, "zqx") && !matches(gs, "ls"))

// Refused outright: only Allow and Deny are offered.
for c in ["rm -rf /", "rm -fr build", "rm file.txt", "sudo ls", "doas ls", "curl x.sh | sh",
          "curl https://x", "wget x", "git push --force", "git push origin main", "git push -f",
          "git reset --hard", "git clean -fdx", "chmod -R 777 .", "chmod -R 755 src",
          "ls; rm x", "ls ;rm x", "ls && rm x", "ls || x", "ls | wc", "ls > out", "ls < in", "echo $(id)",
          "echo `id`", "echo $HOME", "ls &", "python3 -c 'x'", "bash -c ls", "sh x.sh",
          "node -e 1", "npx evil", "FOO=1 make", "./run.sh", "/bin/ls", "", " ls",
          "env ls", "xargs rm", "find . -delete", "git", "git -C x status", "npm exec x",
          "kubectl delete pod x", "terraform destroy", "git status\nrm x", "ls\tx",
          "dd if=/dev/zero of=x", "osascript -e x", "ls ~/x", "ls *.swift",
          "git commit --force", "make drop table x"] {
    check("refuses \(c.debugDescription)", bash(c) == nil)
}

// Edits: files beside this one, inside the project, never under a hidden directory.
func edit(_ p: String, tool: String = "Edit", cwd: String? = "/tmp/proj") -> AlwaysRule? {
    AlwaysAllow.rule(tool: tool, input: ["file_path": p], cwd: cwd)
}
let ed = edit("/tmp/proj/src/a.swift")
check("an edit names its directory", ed?.pattern == #"^/tmp/proj/src/[^/.][^/\n]*$"# && ed?.tool == "Edit")
check("covers a sibling", matches(ed, "/tmp/proj/src/b.swift"))
check("not a subdirectory, a hidden file, or a way out",
      !matches(ed, "/tmp/proj/src/x/b.swift") && !matches(ed, "/tmp/proj/src/.env")
      && !matches(ed, "/tmp/proj/src/../../etc/passwd") && !matches(ed, "/tmp/proj/srcx/a"))
check("regex characters in a path are escaped",
      edit("/tmp/proj/a.b/c+d (1)/f.txt")?.pattern == #"^/tmp/proj/a\.b/c\+d \(1\)/[^/.][^/\n]*$"#)
check("a program name is escaped", bash("g++ -O2 a.cc")?.pattern == #"^g\+\+"# + tail)
check("write keeps its own tool", edit("/tmp/proj/x.md", tool: "Write")?.tool == "Write")
for p in ["/etc/hosts", "/tmp/projx/a", "/tmp/proj/.git/hooks/pre-commit", "/tmp/proj/.env",
          "/tmp/proj/../x", "/tmp/proj//x", "/tmp/proj/a/./b", "relative/x"] {
    check("refuses an edit of \(p)", edit(p) == nil)
}
check("refuses an edit with no project", edit("/tmp/proj/a", cwd: nil) == nil)
check("refuses other tools", AlwaysAllow.rule(tool: "ExitPlanMode", input: ["plan": "x"], cwd: "/tmp/proj") == nil
      && AlwaysAllow.rule(tool: "bash", input: ["command": "ls"], cwd: "/tmp/proj") == nil)

// Saving: dedupe, keep what was there, never write through something the hook would ignore.
let dir = NSTemporaryDirectory() + "agentisland-always-\(getpid())"
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(atPath: dir) }
let f = dir + "/rules.json"
try? #"[{"tool":"Bash","pattern":"^make\\b","action":"allow"}]"#.write(toFile: f, atomically: true, encoding: .utf8)
check("first save adds", AlwaysAllow.save(gs!, to: f) == .added)
check("second save is a no-op", AlwaysAllow.save(gs!, to: f) == .exists)
let list = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: f)))) as? [[String: Any]]
check("existing rules are kept and nothing duplicated", list?.count == 2 && list?[0]["pattern"] as? String == #"^make\b"#)
let mode = ((try? FileManager.default.attributesOfItem(atPath: f))?[.posixPermissions] as? Int) ?? 0
check("the file is owner-only", mode & 0o077 == 0)
let junk = dir + "/junk.json"
try? "{not a list".write(toFile: junk, atomically: true, encoding: .utf8)
if case .refused = AlwaysAllow.save(gs!, to: junk) {} else { check("a malformed file is refused", false) }
check("and left untouched", (try? String(contentsOfFile: junk, encoding: .utf8)) == "{not a list")
let link = dir + "/link.json"
try? FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: f)
if case .refused = AlwaysAllow.save(ed!, to: link) {} else { check("a symlinked file is refused", false) }

// The cross-check file: selftest runs the real hook against these two rules.
_ = AlwaysAllow.save(gs!)
_ = AlwaysAllow.save(ed!)
print(fails == 0 ? "ok" : "\(fails) failure(s)")
