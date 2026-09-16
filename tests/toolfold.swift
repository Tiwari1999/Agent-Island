// Folding must compress noise without hiding the two calls a reader is looking for: the one
// that failed and the one still running. Run: see AGENTS.md; needs the SDKROOT fallback.
import Foundation

@main enum ToolFoldCheck {
  static func call(_ tool: String, why: String = "w", err: Bool = false,
                   running: Bool = false, agent: String? = nil) -> ToolCall {
    ToolCall(id: UUID().uuidString, tool: tool, why: why,
             response: running ? nil : (err ? "boom" : "ok"),
             isError: err, seconds: 1, subagentKind: agent)
  }

  static func main() {
    var fails = 0
    func check(_ name: String, _ ok: Bool, _ detail: String = "") {
      print("  \(ok ? "PASS" : "FAIL")  \(name)" + (detail.isEmpty ? "" : "  — \(detail)"))
      if !ok { fails += 1 }
    }

    let run = ToolCalls.fold([call("Bash"), call("Bash"), call("Bash")])
    check("a run of one tool folds to a single line", run.count == 1, "\(run.count) rows")
    check("and counts every call it stands for", run.first?.runLength == 3, "\(run.first?.runLength ?? 0)")

    let mixed = ToolCalls.fold([call("Bash"), call("Bash"), call("Read"), call("Bash")])
    check("a different tool breaks the run", mixed.count == 3,
          mixed.map { "\($0.runLength)x\($0.tool)" }.joined(separator: ","))

    let failed = ToolCalls.fold([call("Bash"), call("Bash", err: true), call("Bash")])
    check("a FAILED call is never folded away", failed.count == 3 && failed.contains { $0.isError },
          failed.map { "\($0.runLength)x\($0.tool)\($0.isError ? "!" : "")" }.joined(separator: ","))

    let live = ToolCalls.fold([call("Bash"), call("Bash", running: true), call("Bash")])
    check("a RUNNING call is never folded away", live.count == 3 && live.contains { $0.running })

    let sub = ToolCalls.fold([call("Task", agent: "code-reviewer"), call("Task", agent: "code-reviewer")])
    check("subagent launches stay separate", sub.count == 2)

    check("folding never invents or loses calls",
          ToolCalls.fold([call("Bash"), call("Bash"), call("Read")]).reduce(0) { $0 + $1.runLength } == 3)

    check("an empty list folds to nothing", ToolCalls.fold([]).isEmpty)

    // Against the real thing: the row is capped at 5 entries, so the win is how many actual
    // calls those 5 entries now stand for.
    if let sid = CommandLine.arguments.dropFirst().first {
      let raw = ToolCalls.parse(Tail.read(path: Transcript.path(sessionId: sid, cwd: nil) ?? "",
                                          bytes: 2 * 1024 * 1024))
      let folded = ToolCalls.fold(raw)
      let shown = Array(folded.prefix(5))
      print("\n  real transcript: \(raw.count) calls -> \(folded.count) rows; "
            + "the 5 shown now cover \(shown.reduce(0) { $0 + $1.runLength }) calls")
    }
    print(fails == 0 ? "\nRESULT: 0 failures" : "\nRESULT: \(fails) failure(s)")
    exit(fails == 0 ? 0 : 1)
  }
}
