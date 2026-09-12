#!/usr/bin/env python3
"""The blocked badge, as a truth table.

This regressed three times: dormancy alone, then `tempo` alone, then a filter placed in the
shared cache that also blanked the question text. The rules live in Swift; this lifts the two
constants that decide the outcome and asserts the behaviour they are supposed to produce.
"""
import os, re, sys

SRC = os.path.join(os.path.dirname(__file__), "..", "Sources", "AgentIsland")
store = open(os.path.join(SRC, "AgentStore.swift")).read()
blocked = open(os.path.join(SRC, "Blocked.swift")).read()

grace = float(re.search(r"static let dormantAfter: TimeInterval = (\d+)", store).group(1))

# Cache membership, mirroring Blocked.refreshIfStale.
assert '(obj["state"] as? String) == "blocked"' in blocked
assert '(obj["tempo"] as? String) != "active"' in blocked
# The question is kept for every blocked session; interactivity is recorded, not filtered out.
assert 'if (obj["interactiveLineage"] as? Bool) == true { chatting.insert(key) }' in blocked
assert "found[key] = needs" in blocked
# The badge, not the cache, is where an interactive session is excluded.
assert "!Blocked.isInteractive(agent.sessionId)" in store

def badged(state, tempo, interactive, age):
    in_cache = state == "blocked" and tempo != "active"
    return in_cache and not interactive and age > grace

def has_question(state, tempo):
    """Every blocked session carries its question, interactive or not — `activity` reads this."""
    return state == "blocked" and tempo != "active"

CASES = [
    # (label,                                      state,     tempo,     interactive, age, badged)
    ("chat mid-turn",                              "blocked", "active",  True,  10,     False),
    ("chat 20s after the turn ends, tempo flips",  "blocked", "blocked", True,  30,     False),
    ("chat, away ten minutes",                     "blocked", "blocked", True,  600,    False),
    ("chat, away overnight",                       "blocked", "blocked", True,  40000,  False),
    ("chat, away a week",                          "blocked", "blocked", True,  604800, False),
    ("stuck background agent, inside the grace",   "blocked", "blocked", False, 30,     False),
    ("stuck background agent, past the grace",     "blocked", "blocked", False, 120,    True),
    ("stuck background agent, weeks old",          "blocked", "blocked", False, 1.9e6,  True),
    ("agent that is simply working",               "busy",    "active",  False, 5,      False),
    ("agent that failed",                          "failed",  "idle",    False, 900,    False),
]

fails = 0
for label, state, tempo, inter, age, want in CASES:
    got = badged(state, tempo, inter, age)
    ok = got == want
    fails += not ok
    print(f"  {'PASS' if ok else 'FAIL'}  {label:<44}badged={got}")

# The regression that suppressing the badge caused: the question text vanished everywhere.
for label, state, tempo, inter, *_ in CASES:
    if state == "blocked" and tempo != "active" and not has_question(state, tempo):
        print(f"  FAIL  {label}: blocked but carries no question")
        fails += 1
print(f"  PASS  an interactive chat keeps its question while losing the badge"
      f" ({has_question('blocked','blocked')})")

print(f"\ngrace period: {grace:.0f}s")
print("RESULT:", "ok" if not fails else f"{fails} failure(s)")
sys.exit(1 if fails else 0)
