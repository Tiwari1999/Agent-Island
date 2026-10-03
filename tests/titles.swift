// Cases for which title a Claude row shows. NOT run on its own: tests/selftest.py lifts the real
// Titles.swift and Tail out of the app, stubs Transcript.path, and appends this file.
var fails = 0
func check(_ n: String, _ ok: Bool) { if !ok { print("FAIL \(n)"); fails += 1 } }

let dir = FileManager.default.temporaryDirectory
    .appendingPathComponent("agentisland-titles-\(getpid())")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: dir) }

var n = 0
// A fresh session each time, with its own mtime, so no case reads another's cache.
func session(_ lines: [String]) -> String {
    n += 1
    let id = "s\(n)"
    let path = dir.appendingPathComponent("\(id).jsonl").path
    try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    Transcript.paths[id] = path
    return id
}
func line(_ type: String, _ key: String, _ v: String) -> String { "{\"type\":\"\(type)\",\"\(key)\":\"\(v)\"}" }
let ai = line("ai-title", "aiTitle", "Generated name")

check("the generated title shows when nothing was renamed",
      Titles.title(for: session([ai]), cwd: nil) == "Generated name")
check("a /rename beats the generated title",
      Titles.title(for: session([ai, line("custom-title", "customTitle", "My name")]), cwd: nil) == "My name")
check("even when the generated title is written after it",
      Titles.title(for: session([line("custom-title", "customTitle", "My name"), ai]), cwd: nil) == "My name")
check("the newest rename wins",
      Titles.title(for: session([line("custom-title", "customTitle", "First"),
                                 line("custom-title", "customTitle", "Second")]), cwd: nil) == "Second")

// The rename has scrolled out of the tail: Claude keeps it beside the transcript as well.
let side = session([ai])
let sideDir = dir.appendingPathComponent(side)
try? FileManager.default.createDirectory(at: sideDir, withIntermediateDirectories: true)
try? "{\"customTitle\":\"From the sidecar\"}"
    .write(to: sideDir.appendingPathComponent("custom-title.json"), atomically: true, encoding: .utf8)
check("a rename kept only in custom-title.json still shows",
      Titles.title(for: side, cwd: nil) == "From the sidecar")

// Renaming a live session appends a line; the next read must pick it up, not the cached title.
let live = session([ai])
_ = Titles.title(for: live, cwd: nil)
let h = FileHandle(forWritingAtPath: Transcript.paths[live]!)!
h.seekToEndOfFile(); h.write((line("custom-title", "customTitle", "Renamed live") + "\n").data(using: .utf8)!)
try? h.close()
try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)],
                                       ofItemAtPath: Transcript.paths[live]!)
check("renaming a running session updates the row", Titles.title(for: live, cwd: nil) == "Renamed live")

print(fails == 0 ? "ok" : "\(fails) failed")
