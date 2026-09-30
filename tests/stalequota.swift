// Cases for the quota footer's freshness rule. NOT run on its own: tests/selftest.py lifts the
// real isStale/remaining bodies out of Status.swift, wraps them in `enum Q`, and appends this —
// so breaking either function in the app fails here rather than passing a text match.
//
// The bug: a reset time that has already passed rendered "now" for ever, beside a used% that
// was just as old. Both read as live when only the clock had moved.
var fails = 0
func check(_ n: String, _ ok: Bool) { if !ok { print("FAIL \(n)"); fails += 1 } }
func at(_ s: TimeInterval) -> Date { Date().addingTimeInterval(s) }

check("no reset time is not staleness", !Q.isStale(nil))
check("and prints nothing at all", Q.remaining(nil) == "")
check("a future window is fresh", !Q.isStale(at(3600)))
check("and counts down", Q.remaining(at(3600 + 120)) == "1h2m")
check("days collapse to d+h", Q.remaining(at(26 * 3600)) == "1d2h")
// The grace: a window that just rolled over is not yet evidence of a dead writer, and
// flashing "stale" at every reset would cry wolf five times a day.
check("a window that just turned over is still fresh", !Q.isStale(at(-30)))
check("and still says now", Q.remaining(at(-30)) == "now")
check("five minutes past is the edge, not yet stale", !Q.isStale(at(-299)))
check("well past the grace is stale", Q.isStale(at(-3600)))
check("and says so instead of 'now'", Q.remaining(at(-3600)) == "stale")
check("a day-old timestamp is stale too", Q.isStale(at(-86400)))

print(fails == 0 ? "ok" : "\(fails) failure(s)")
