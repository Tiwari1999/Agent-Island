// A versioned-symlink install reports p_comm as the version string ("2.1.267"), not "claude",
// so the old comm-only match bound no pid and every jump silently no-op'd; this proves the
// argv[0] fallback still binds such a process.
// Run: swiftc -parse-as-library tests/procname.swift Sources/AgentIsland/Proc.swift -o /tmp/procname && /tmp/procname
import Darwin
import Foundation

@main enum ProcNameCheck {
  static func main() {
    let comm = Proc.all()
var checked = 0, missReal = 0, missVersioned = 0
var examples: [String] = []

for (pid, name) in comm {
    // Identify an agent process by argv[0] alone, independent of p_comm.
    guard let argv0 = Proc.argsEnv(pid: Int(pid))?.argv.first else { continue }
    let base = (argv0 as NSString).lastPathComponent
    guard Proc.agentNames.contains(base) else { continue }
    checked += 1

    // Its real p_comm must match (directly, or via the fallback for a versioned install).
    if !Proc.matches(pid: Int(pid), comm: name, names: Proc.agentNames) { missReal += 1 }

    // Simulate the friend's install: p_comm is a version string. The fix must still bind it.
    if !Proc.matches(pid: Int(pid), comm: "2.1.267", names: Proc.agentNames) {
        missVersioned += 1
    } else if examples.count < 3 {
        examples.append("pid \(pid): comm=\(name) argv0=\(base) → bound")
    }
}

print("agent processes seen:        \(checked)")
print("missed with real p_comm:     \(missReal)")
print("missed with version p_comm:  \(missVersioned)   (the friend's bug — must be 0)")
for e in examples { print("  \(e)") }

// The old comm-only match would have missed a version-named process outright.
let oldLogicMisses = !Proc.agentNames.contains("2.1.267")
print("old comm-only logic misses a version-named process: \(oldLogicMisses)")

if checked == 0 {
    print("SKIP: no agent process running to check")
    exit(0)
}
let ok = missReal == 0 && missVersioned == 0
print(ok ? "RESULT: ok \(checked)" : "RESULT: FAIL")
exit(ok ? 0 : 1)
  }
}
