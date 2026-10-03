// Branch chip and project grouping against real repos. NOT run on its own: tests/selftest.py
// prepends the app's real Git.swift. Fixtures are made by real git; the reader itself never runs it.
var fails = 0
func check(_ n: String, _ ok: Bool) { if !ok { print("FAIL \(n)"); fails += 1 } }

let fm = FileManager.default
// Unresolved on purpose (/var, not /private/var): git writes worktree paths resolved.
let tmp = fm.temporaryDirectory.appendingPathComponent("agentisland-git-\(getpid())").path
try? fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
defer { try? fm.removeItem(atPath: tmp) }

@discardableResult
func git(_ dir: String, _ args: String...) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = ["-C", dir, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "init.defaultBranch=main"] + args
    let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
    try? p.run(); p.waitUntilExit()
    return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}
func mkdir(_ p: String) -> String { try? fm.createDirectory(atPath: p, withIntermediateDirectories: true); return p }
func real(_ p: String) -> String { URL(fileURLWithPath: p).resolvingSymlinksInPath().path }

let repo = mkdir(tmp + "/repo")
git(repo, "init", "-q")
git(repo, "commit", "-q", "--allow-empty", "-m", "one")
let sub = mkdir(repo + "/src/deep")

let main = Git.info(cwd: sub)
check("a normal repo shows its branch, from a subdirectory too", main?.branch == "main")
check("and is not a worktree", main?.isWorktree == false)
check("and its project is the repo", main.map { real($0.root) } == real(repo))

let wt = tmp + "/wt-x"
git(repo, "worktree", "add", "-q", "-b", "feat/x", wt)
let w = Git.info(cwd: wt)
check("a linked worktree shows its own branch", w?.branch == "feat/x")
check("and says it is a worktree", w?.isWorktree == true)
check("and groups under the main repo", w?.root == main?.root)
check("the chip marks a worktree", w?.chip == "⎇ feat/x · wt" && main?.chip == "⎇ main")

let det = tmp + "/wt-detached"
git(repo, "worktree", "add", "-q", "--detach", det)
check("a detached HEAD shows the short sha",
      Git.info(cwd: det)?.branch == git(repo, "rev-parse", "--short=7", "HEAD"))

check("a directory outside any repo shows nothing", Git.info(cwd: mkdir(tmp + "/plain")) == nil)

// Packed refs: the branch's loose ref is gone, HEAD still names it symbolically.
git(repo, "pack-refs", "--all")
check("packing refs leaves no loose ref behind", !fm.fileExists(atPath: repo + "/.git/refs/heads/main"))
let packed = mkdir(tmp + "/packed")
git(packed, "init", "-q"); git(packed, "commit", "-q", "--allow-empty", "-m", "p")
git(packed, "pack-refs", "--all")
git(packed, "symbolic-ref", "HEAD", "refs/heads/release/2.0")
check("a symbolic HEAD names its branch with no ref file to read", Git.info(cwd: packed)?.branch == "release/2.0")

// A submodule-style checkout: `.git` is a relative gitdir file, but with no commondir it is no worktree.
let modGit = mkdir(tmp + "/modgit")
try? "ref: refs/heads/topic\n".write(toFile: modGit + "/HEAD", atomically: true, encoding: .utf8)
let mod = mkdir(tmp + "/mod")
try? "gitdir: ../modgit\n".write(toFile: mod + "/.git", atomically: true, encoding: .utf8)
let m = Git.info(cwd: mod)
check("a relative gitdir file resolves", m?.branch == "topic")
check("and without commondir it is not called a worktree", m?.isWorktree == false && m.map { real($0.root) } == real(mod))

// Cache: keyed on HEAD's mtime, so unchanged bytes are not re-read; a checkout is picked up.
let head = repo + "/.git/HEAD"
// A whole-second stamp, so setting it back is exact; the first read caches it.
let stamp = Date(timeIntervalSince1970: 1_700_000_000)
try? fm.setAttributes([.modificationDate: stamp], ofItemAtPath: head)
_ = Git.info(cwd: sub)
try? "ref: refs/heads/sneaky\n".write(toFile: head, atomically: false, encoding: .utf8)
try? fm.setAttributes([.modificationDate: stamp], ofItemAtPath: head)
check("an unchanged HEAD mtime is served from cache", Git.info(cwd: sub)?.branch == "main")
Git.retain([wt])
check("retain evicts a cwd that is gone", Git.info(cwd: sub)?.branch == "sneaky")
git(repo, "checkout", "-q", "-b", "feat/y")
check("a checkout is picked up on the next read", Git.info(cwd: sub)?.branch == "feat/y")
// The worktree's `gitdir:` file is watched too: re-pointing it re-resolves.
let wtGit = wt + "/.git"
let wtStamp = (try? fm.attributesOfItem(atPath: wtGit))?[.modificationDate] as? Date
try? "gitdir: ../modgit\n".write(toFile: wtGit, atomically: false, encoding: .utf8)
try? fm.setAttributes([.modificationDate: wtStamp!.addingTimeInterval(5)], ofItemAtPath: wtGit)
check("a re-pointed worktree file is re-read", Git.info(cwd: wt)?.branch == "topic")

let long = GitInfo(branch: "feat/an-extremely-long-branch-name-here", isWorktree: false, root: "/r")
check("a long branch keeps its head and tail", long.chip == "⎇ feat/an-ext…ch-name-here")

let groups = Git.grouped(["b1", "a1", "b2", "c1", "a2"]) { String($0.prefix(1)) }
check("grouping keeps first-seen order across and within groups",
      groups.map(\.key) == ["b", "a", "c"] && groups[0].items == ["b1", "b2"] && groups[1].items == ["a1", "a2"])

print(fails == 0 ? "ok" : "\(fails) failed")
