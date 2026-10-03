// Cases for follow-up reminders. NOT run on its own: tests/selftest.py prepends the real
// Sources/AgentIsland/Reminders.swift, so these drive the shipped scheduler with a fake clock.
var fails = 0
func check(_ n: String, _ ok: Bool) { if !ok { print("FAIL \(n)"); fails += 1 } }
let t0 = Date(timeIntervalSince1970: 1_000_000)
func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
let five: TimeInterval = 300

// An ask is nudged three times, an interval apart, then never again.
var r = Reminders(interval: five)
r.track(.approval, session: "A", item: "ap1", now: t0)
check("nothing before the interval", r.collect(now: at(299), locked: false, looking: false).isEmpty)
check("the timer is set for exactly one interval out", r.nextDue == at(300))
let first = r.collect(now: at(300), locked: false, looking: false)
check("first nudge at the interval", first.map(\.attempt) == [1] && first[0].key.item == "ap1")
check("next one an interval after the last", r.nextDue == at(600))
check("second", r.collect(now: at(600), locked: false, looking: false).map(\.attempt) == [2])
check("third", r.collect(now: at(900), locked: false, looking: false).map(\.attempt) == [3])
check("and that was the last: nothing pending, nothing scheduled", r.isEmpty && r.nextDue == nil)
check("so no fourth however long it waits",
      r.collect(now: at(99_999), locked: false, looking: false).isEmpty)
check("a re-report of the same ask keeps its timing", {
    var q = Reminders(interval: five)
    q.track(.question, session: "A", item: "q1", now: t0)
    q.track(.question, session: "A", item: "q1", now: at(200))
    return q.nextDue == at(300)
}())

// A finished turn blocks nothing: one nudge.
r = Reminders(interval: five)
r.track(.completion, session: "A", item: "finished", now: t0)
check("a finish gets one reminder", r.collect(now: at(300), locked: false, looking: false).count == 1)
check("and only one", r.isEmpty && r.nextDue == nil)

// Answering, or jumping to the session, ends it on the spot.
r = Reminders(interval: five)
r.track(.approval, session: "A", item: "ap1", now: t0)
r.track(.question, session: "A", item: "q1", now: t0)
r.cancel(session: "A", item: "ap1")
check("answering one ask leaves the other",
      r.collect(now: at(300), locked: false, looking: false).map(\.key.item) == ["q1"])
r.track(.completion, session: "B", item: "finished", now: at(300))
r.cancel(session: "A")
check("a jump clears every reminder of that session", !r.keys.contains { $0.session == "A" })
check("and none of another's", r.keys == [Reminders.Key(session: "B", item: "finished")])
r.cancel(session: "B")
check("cancelling the last one leaves nothing to wake for", r.isEmpty && r.nextDue == nil)

// Two sessions, same request id: neither may answer, count or cancel for the other.
r = Reminders(interval: five)
r.track(.question, session: "A", item: "q1", now: t0)
r.track(.question, session: "B", item: "q1", now: at(60))
check("each session nudged on its own clock",
      r.collect(now: at(300), locked: false, looking: false).map(\.key.session) == ["A"])
r.cancel(session: "A", item: "q1")
let b = r.collect(now: at(360), locked: false, looking: false)
check("cancelling A's q1 leaves B's", b.map(\.key.session) == ["B"] && b[0].attempt == 1)

// Locked: due nudges are held, missed attempts collapse, and unlock delivers one catch-up.
r = Reminders(interval: five)
r.track(.question, session: "A", item: "q1", now: t0)
r.track(.approval, session: "B", item: "ap1", now: at(10))
r.track(.approval, session: "C", item: "ap2", now: at(20))
check("nothing plays while locked", r.collect(now: at(400), locked: true, looking: false).isEmpty)
check("and owed ones set no timer — the unlock wakes them", r.nextDue == nil && r.keys.count == 3)
check("still nothing three intervals later", r.collect(now: at(1300), locked: true, looking: false).isEmpty)
let caught = r.collect(now: at(1500), locked: false, looking: false)
check("unlock delivers exactly one catch-up", caught.count == 1 && caught[0].catchUp)
check("the most urgent: the oldest approval", caught.first?.key == Reminders.Key(session: "B", item: "ap1"))
check("which spent one attempt, not three", caught.first?.attempt == 1)
check("the rest wait a fresh interval, unspent", r.nextDue == at(1800) && r.keys.count == 3)
let later = r.collect(now: at(1800), locked: false, looking: false)
check("then come on time, as first attempts", later.map(\.attempt).sorted() == [1, 1, 2]
      && later.allSatisfy { !$0.catchUp })

// Already looking: an ask waits another interval for free; a finish counts as seen.
r = Reminders(interval: five)
r.track(.approval, session: "A", item: "ap1", now: t0)
r.track(.completion, session: "B", item: "finished", now: t0)
check("nothing while the user is looking", r.collect(now: at(300), locked: false, looking: true).isEmpty)
check("the finish was seen", r.keys == [Reminders.Key(session: "A", item: "ap1")])
check("the ask is deferred one interval", r.nextDue == at(600))
check("without spending an attempt", r.collect(now: at(600), locked: false, looking: false).first?.attempt == 1)

// Off schedules nothing at all, and turning it off forgets what was pending.
r = Reminders(interval: nil)
r.track(.approval, session: "A", item: "ap1", now: t0)
check("Off tracks nothing", r.isEmpty && r.nextDue == nil)
check("Off collects nothing", r.collect(now: at(99_999), locked: false, looking: false).isEmpty)
r.setInterval(120)
r.track(.approval, session: "A", item: "ap1", now: t0)
check("2 min is honoured", r.nextDue == at(120))
r.setInterval(600)
check("a new interval re-times what is pending", r.nextDue == at(600))
r.setInterval(0)
check("switching Off drops it and schedules nothing", r.isEmpty && r.nextDue == nil)
check("a fresh scheduler has nothing to wake for", Reminders(interval: five).nextDue == nil)

// The owner's truth check gets each ask's start, so stale state cannot cancel a newer ask.
r = Reminders(interval: five)
r.track(.question, session: "A", item: "q1", now: t0)
r.track(.question, session: "B", item: "q2", now: at(100))
r.keep { _, _, since in since > at(50) }
check("keep sees when each ask began", r.keys == [Reminders.Key(session: "B", item: "q2")])

print(fails == 0 ? "ok" : "\(fails) failure(s)")
