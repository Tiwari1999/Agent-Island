import Foundation
// Mirrors CursorSource.claimPids. Kept in step by hand; the suite checks both still agree.
struct A { var sessionId: String; var pid: Int?; var at: Date? }
func claim(_ agents: [A]) -> [A] {
    var best: [Int: String] = [:]
    for a in agents {
        guard let pid = a.pid else { continue }
        guard let held = best[pid] else { best[pid] = a.sessionId; continue }
        let heldAt = agents.first { $0.sessionId == held }?.at ?? .distantPast
        if (a.at ?? .distantPast) > heldAt { best[pid] = a.sessionId }
    }
    return agents.map { a in
        guard let pid = a.pid, best[pid] != a.sessionId else { return a }
        var s = a; s.pid = nil; return s
    }
}
var fails = 0
func check(_ n: String, _ ok: Bool) { print(ok ? "  PASS  \(n)" : "  FAIL  \(n)"); if !ok { fails += 1 } }
let t0 = Date(timeIntervalSince1970: 1_000_000)
let three = [A(sessionId: "old", pid: 42, at: t0),
             A(sessionId: "newest", pid: 42, at: t0.addingTimeInterval(60)),
             A(sessionId: "mid", pid: 42, at: t0.addingTimeInterval(30))]
let r = claim(three)
check("only one row keeps the shared pid", r.filter { $0.pid != nil }.count == 1)
check("and it is the most recently updated one",
      r.first { $0.pid != nil }?.sessionId == "newest")
check("the others are stripped, not dropped", r.count == 3)

let distinct = [A(sessionId: "a", pid: 1, at: t0), A(sessionId: "b", pid: 2, at: t0)]
check("two chats on two processes both keep theirs",
      claim(distinct).filter { $0.pid != nil }.count == 2)

let none = [A(sessionId: "x", pid: nil, at: t0)]
check("a row with no pid is untouched", claim(none).first?.pid == nil)

// Order must not decide the winner: the newest wins whether it is seen first or last.
let reversed = Array(three.reversed())
check("the winner does not depend on iteration order",
      claim(reversed).first { $0.pid != nil }?.sessionId == "newest")

// Ties must still leave exactly one claimant rather than none or both.
let tied = [A(sessionId: "p", pid: 7, at: t0), A(sessionId: "q", pid: 7, at: t0)]
check("a tie still yields exactly one claimant",
      claim(tied).filter { $0.pid != nil }.count == 1)
print(fails == 0 ? "RESULT: 0 failure(s)" : "RESULT: \(fails) failure(s)")
