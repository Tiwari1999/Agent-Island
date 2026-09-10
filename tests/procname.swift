// Is an agent process still recognised when p_comm is not its name? Compiled against the real
// Proc.swift, so it checks the shipping logic rather than a copy of it.
//
// The regression it guards: p_comm is the basename of the *resolved* executable. Claude Code's
// native installer symlinks ~/.local/bin/claude at a version-named binary, so p_comm reads
// "2.1.267" and a match against "claude" fails. That bound no pid to any session, which left
// every row's host unknown and made every jump a silent no-op.
import Foundation

@main
enum ProcNameCheck {
    static func main() {
        var bad: [String] = []

        // Synthetic p_comm values, so the check holds on any machine and whatever is installed
        // on it. `matches` is asked about this very process, whose argv[0] we control.
        let me = Int(getpid())
        let mine = (CommandLine.arguments.first! as NSString).lastPathComponent
        let names: Set<String> = [mine]

        // A versioned install: p_comm is the version, argv[0] still carries the name.
        if !Proc.matches(pid: me, comm: "2.1.267", names: names) {
            bad.append("version-string p_comm not recovered from argv[0]")
        }
        // The ordinary install: p_comm is the name. Must not regress into an argv-only check.
        if !Proc.matches(pid: me, comm: mine, names: names) {
            bad.append("plain p_comm no longer matches")
        }
        // Neither name matches: still a miss, so a reused pid cannot inherit a binding.
        if Proc.matches(pid: me, comm: "2.1.267", names: ["definitely-not-this"]) {
            bad.append("matched a name it should not have")
        }
        // A pid that cannot exist must not match on anything.
        if Proc.matches(pid: 0x7FFFFFF, comm: nil, names: names) {
            bad.append("matched a dead pid")
        }
        // And the sweep must find this process by the name it was invoked as.
        if !Proc.pids(named: names).contains(me) {
            bad.append("pids(named:) missed the running process")
        }

        print(bad.isEmpty ? "ok" : "FAIL: " + bad.joined(separator: "; "))
    }
}
