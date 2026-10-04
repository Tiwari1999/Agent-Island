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
    ("a MonoCode Codex session", ["source": "vscode", "originator": "monocode"]),
]
let automated: [(String, [String: Any])] = [
    ("a Codex subagent", ["source": ["subagent": ["thread_spawn": ["parent_thread_id": "x"]]],
                          "originator": "codex_exec", "thread_source": "subagent"]),
    ("a codex exec run", ["source": "exec", "originator": "codex_exec", "thread_source": "user"]),
    ("Codex embedded by Claude Code", ["source": "vscode", "originator": "Claude Code"]),
    ("MonoCode's title helper", ["source": "vscode", "originator": "monocode-text"]),
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

// A stream-json session (MonoCode) opens with queue lines too; only a file of nothing else is a queue file.
let q = "{\"type\":\"queue-operation\",\"operation\":\"enqueue\",\"content\":\"hi\"}\n"
func file(_ n: String, _ s: String) -> String {
    let p = dir.appendingPathComponent(n).path; try? s.write(toFile: p, atomically: true, encoding: .utf8); return p
}
check("a file of queue lines alone is a queue file", Q.onlyQueueLines(path: file("q.jsonl", q + q)))
check("queue lines then a conversation are a session",
      !Q.onlyQueueLines(path: file("m.jsonl", q + q + "{\"parentUuid\":null}\n")))
// The first conversation line carries every tool schema, ~10 KB: a cut-off read must not hide it.
check("a conversation line past the read window still counts",
      !Q.onlyQueueLines(path: file("l.jsonl", q + "{\"parentUuid\":null,\"pad\":\"" + String(repeating: "a", count: 9000) + "\"}\n")))

print(fails == 0 ? "ok" : "\(fails) failed")
