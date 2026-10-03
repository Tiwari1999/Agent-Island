// Which sessions count as someone's own. NOT run on its own: tests/selftest.py lifts the real
// CodexSource.drivenByPerson, ClaudeSource.isHeadless and Tail out of the app and appends this.
var fails = 0
func check(_ n: String, _ ok: Bool) { if !ok { print("FAIL \(n)"); fails += 1 } }

// Codex session_meta payloads, in the shapes real rollouts carry.
let person: [(String, [String: Any])] = [
    ("the Codex terminal app", ["source": "cli", "originator": "codex-tui", "thread_source": "user"]),
    ("Codex Desktop", ["source": "vscode", "originator": "Codex Desktop"]),
    ("the Codex VS Code extension", ["source": "vscode", "originator": "codex_vscode"]),
    ("an older rollout with no originator", ["source": "cli"]),
]
let automated: [(String, [String: Any])] = [
    ("a Codex subagent", ["source": ["subagent": ["thread_spawn": ["parent_thread_id": "x"]]],
                          "originator": "codex_exec", "thread_source": "subagent"]),
    ("a codex exec run", ["source": "exec", "originator": "codex_exec", "thread_source": "user"]),
    ("Codex embedded by Claude Code", ["source": "vscode", "originator": "Claude Code"]),
    ("a subagent marked only by thread_source", ["source": "cli", "originator": "codex-tui",
                                                 "thread_source": "subagent"]),
]
for (n, m) in person { check("keeps \(n)", Q.drivenByPerson(m)) }
for (n, m) in automated { check("hides \(n)", !Q.drivenByPerson(m)) }

// Claude transcripts: a headless `claude -p` run says sdk-cli, ~11 KB in on real files.
let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agentisland-sub-\(getpid())")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: dir) }
func transcript(_ id: String, _ entry: String?, pad: Int = 11_000) -> String {
    var s = "{\"type\":\"ai-title\",\"aiTitle\":\"x\"}\n{\"type\":\"meta\",\"pad\":\"" + String(repeating: "a", count: pad) + "\"}\n"
    if let e = entry { s += "{\"type\":\"user\",\"entrypoint\":\"\(e)\"}\n" }
    let p = dir.appendingPathComponent("\(id).jsonl").path
    try? s.write(toFile: p, atomically: true, encoding: .utf8)
    return p
}
check("hides a headless claude -p run", Q.isHeadless(path: transcript("h", "sdk-cli"), id: "h"))
check("keeps an interactive session", !Q.isHeadless(path: transcript("c", "cli"), id: "c"))
check("keeps a session that has not said yet", !Q.isHeadless(path: transcript("u", nil), id: "u"))
// Undecided must not be cached as "keep": once the line arrives, the run is hidden.
_ = transcript("u", "sdk-cli")
check("decides later when the entrypoint appears", Q.isHeadless(path: dir.appendingPathComponent("u.jsonl").path, id: "u"))

print(fails == 0 ? "ok" : "\(fails) failed")
