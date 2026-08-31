#!/usr/bin/env python3
"""Measure Agent Island's CPU under sustained load, not at idle.

The 0.20% figure everyone quotes was measured with one Claude session and nothing happening.
That is the trivial case for a monitor. This drives the hook spool at a realistic rate for a
named window and reports mean and p95, so the number can be compared against a rival's.
"""
import argparse, json, os, subprocess, sys, time

SPOOL = "/tmp/agentisland-events.jsonl"
PROC = "AgentIsland.app/Contents/MacOS/AgentIsland"


def pid():
    out = subprocess.run(["pgrep", "-f", PROC], capture_output=True, text=True).stdout.split()
    return out[0] if out else None


def cpu_seconds(p):
    out = subprocess.run(["ps", "-o", "time=", "-p", p], capture_output=True, text=True).stdout.strip()
    if not out:
        return None
    parts = [float(x) for x in out.replace("-", ":").split(":")]
    while len(parts) < 3:
        parts.insert(0, 0.0)
    return parts[-3] * 3600 + parts[-2] * 60 + parts[-1]


def rss_mb(p):
    out = subprocess.run(["ps", "-o", "rss=", "-p", p], capture_output=True, text=True).stdout.strip()
    return int(out) / 1024 if out else None


def drive(sessions, rate, stop):
    """Synthetic tool traffic — a real fleet cannot be conjured on demand, and a benchmark that
    needs ten live agents is a benchmark nobody re-runs."""
    tools = [("Bash", {"command": "swift build -c release"}),
             ("Read", {"file_path": "/Users/x/project/Sources/App/Main.swift"}),
             ("Edit", {"file_path": "/Users/x/project/Sources/App/View.swift"}),
             ("Grep", {"pattern": "func handle"})]
    i = 0
    while time.time() < stop:
        with open(SPOOL, "a") as f:
            for s in range(sessions):
                tool, inp = tools[i % len(tools)]
                for event in ("PreToolUse", "PostToolUse"):
                    f.write(json.dumps({
                        "session_id": f"bench-{s:02d}", "hook_event_name": event,
                        "tool_name": tool, "tool_input": inp, "cwd": "/tmp/bench"}) + "\n")
                i += 1
        time.sleep(1.0 / rate)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sessions", type=int, default=10, help="concurrent sessions to simulate")
    ap.add_argument("--rate", type=float, default=2.0, help="tool-call bursts per second")
    ap.add_argument("--window", type=int, default=300, help="measurement window, seconds")
    ap.add_argument("--idle", action="store_true", help="measure idle instead, for the baseline")
    a = ap.parse_args()

    p = pid()
    if not p:
        sys.exit("AgentIsland is not running")

    mode = "idle" if a.idle else f"{a.sessions} sessions @ {a.rate}/s"
    print(f"  measuring {a.window}s — {mode}")
    print(f"  machine: {subprocess.run(['sysctl','-n','machdep.cpu.brand_string'],capture_output=True,text=True).stdout.strip()}")
    print(f"  macOS:   {subprocess.run(['sw_vers','-productVersion'],capture_output=True,text=True).stdout.strip()}")

    import threading
    stop = time.time() + a.window
    if not a.idle:
        threading.Thread(target=drive, args=(a.sessions, a.rate, stop), daemon=True).start()

    samples, rss = [], []
    last_t, last_c = time.time(), cpu_seconds(p)
    while time.time() < stop:
        time.sleep(5)
        now, c = time.time(), cpu_seconds(p)
        if c is None:
            sys.exit("process exited mid-run")
        samples.append((c - last_c) / (now - last_t) * 100)
        rss.append(rss_mb(p))
        last_t, last_c = now, c

    samples.sort()
    mean = sum(samples) / len(samples)
    p95 = samples[int(len(samples) * 0.95) - 1]
    print(f"\n  CPU  mean {mean:5.2f}%   p95 {p95:5.2f}%   (of one core, {len(samples)} samples)")
    print(f"  RSS  mean {sum(rss)/len(rss):5.1f} MB   max {max(rss):5.1f} MB")
    print(f"\n  Report as: \"{mean:.2f}% mean / {p95:.2f}% p95 at {mode}\" — never as a bare number.")


if __name__ == "__main__":
    main()
