#!/usr/bin/env python3
"""Adversarial input for every hook.

A hook runs inside the user's agent. If one hangs, the session freezes; if one emits malformed
JSON, the agent may misread a permission decision. Neither failure is acceptable, so every hook
must survive garbage and still exit 0 within its budget.
"""
import json, os, subprocess, sys, time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOOKS = {
    "event":      f"{REPO}/hooks/agentisland-hook.sh",
    "permission": f"{REPO}/hooks/agentisland-permission.sh",
    "question":   f"{REPO}/hooks/agentisland-question.py",
    "rules":      f"{REPO}/hooks/agentisland-rules.py",
}

# Each case is (name, stdin). Nothing here may hang or crash a hook.
CASES = [
    ("empty",                b""),
    ("whitespace",           b"   \n\t  "),
    ("not json",             b"this is not json at all"),
    ("truncated json",       b'{"session_id": "abc"'),
    ("null bytes",           b'{"session_id": "a\x00b"}'),
    ("deeply nested",        json.dumps({"a": {"b": {"c": {"d": {"e": {"f": 1}}}}}}).encode()),
    ("huge payload",         json.dumps({"session_id": "x", "tool_input": {"command": "y" * 500_000}}).encode()),
    ("wrong types",          b'{"session_id": 42, "tool_name": ["a"], "tool_input": "str"}'),
    ("unicode",              json.dumps({"session_id": "s", "tool_name": "Bash",
                                         "tool_input": {"command": "echo 🏝️ ünïcödé"}}).encode()),
    ("shell metachars",      json.dumps({"session_id": "s", "tool_name": "Bash",
                                         "tool_input": {"command": "`rm -rf /`; $(whoami)"}}).encode()),
    ("newlines in fields",   json.dumps({"session_id": "a\nb", "tool_name": "Bash",
                                         "tool_input": {"command": "line1\nline2"}}).encode()),
    ("array at top level",   b'[{"session_id": "x"}]'),
    ("missing everything",   b"{}"),
]

BUDGET = 5.0        # seconds; a hook slower than this is a hang risk


def run(path, data, env):
    start = time.time()
    try:
        p = subprocess.run([path], input=data, capture_output=True, timeout=BUDGET, env=env)
    except subprocess.TimeoutExpired:
        return None, time.time() - start, "TIMEOUT"
    elapsed = time.time() - start
    if p.returncode != 0:
        return p, elapsed, f"exit {p.returncode}"
    if p.stdout.strip():
        try:
            json.loads(p.stdout)
        except json.JSONDecodeError:
            return p, elapsed, "malformed stdout"
    return p, elapsed, None


def main():
    env = dict(os.environ,
               AGENTISLAND_SPOOL="/tmp/fuzz-spool.jsonl",
               AGENTISLAND_DECISIONS="/tmp/fuzz-dec",
               AGENTISLAND_ALIVE="/tmp/does-not-exist",     # forces the fall-through path
               AGENTISLAND_RULES="/tmp/does-not-exist.json")
    os.makedirs("/tmp/fuzz-dec", exist_ok=True)

    failures, slowest = [], 0.0
    for hook_name, path in HOOKS.items():
        for case_name, data in CASES:
            _, elapsed, problem = run(path, data, env)
            slowest = max(slowest, elapsed)
            status = "PASS" if problem is None else "FAIL"
            if problem:
                failures.append(f"{hook_name}/{case_name}: {problem}")
            print(f"  {status}  {hook_name:11} {case_name:20} {elapsed*1000:6.0f}ms"
                  + (f"  <- {problem}" if problem else ""))

    print(f"\n  {len(HOOKS)*len(CASES)} cases, slowest {slowest*1000:.0f}ms, budget {BUDGET*1000:.0f}ms")
    if failures:
        print("  FAILURES:")
        for f in failures:
            print(f"    {f}")
    else:
        print("  every hook survived every input, exited 0, and emitted valid JSON or nothing")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
