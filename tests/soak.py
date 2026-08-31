#!/usr/bin/env python3
"""Watch a running Agent Island for leaks and drift.

A monitor is judged over hours, not seconds. Discovery caches grow, file handles accumulate,
and a slow leak looks fine in a 60-second benchmark. This samples memory, handles, CPU and
discovery latency, then reports the trend rather than a snapshot.
"""
import argparse, functools, re, subprocess, sys, time

# Unbuffered: a soak is watched while it runs, and a buffered log that only appears at exit is
# useless for exactly that.
print = functools.partial(__builtins__.print if hasattr(__builtins__, "print")
                          else __import__("builtins").print, flush=True)

PROC = "AgentIsland.app/Contents/MacOS/AgentIsland"
LOG = "/tmp/agentisland.log"


def pid():
    out = subprocess.run(["pgrep", "-f", PROC], capture_output=True, text=True).stdout.split()
    return out[0] if out else None


def sample(p):
    ps = subprocess.run(["ps", "-o", "rss=,time=", "-p", p], capture_output=True, text=True).stdout.split()
    if len(ps) < 2:
        return None
    parts = [float(x) for x in ps[1].replace("-", ":").split(":")]
    while len(parts) < 3:
        parts.insert(0, 0.0)
    fds = subprocess.run(["/bin/sh", "-c", f"lsof -p {p} 2>/dev/null | wc -l"],
                         capture_output=True, text=True).stdout.strip()
    return {"rss": int(ps[0]) / 1024,
            "cpu": parts[-3] * 3600 + parts[-2] * 60 + parts[-1],
            "fds": int(fds or 0)}


def latencies(since):
    try:
        text = open(LOG).read()
    except FileNotFoundError:
        return []
    return [float(m) for m in re.findall(r"in ([\d.]+)s", text)][since:]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--minutes", type=float, default=30)
    ap.add_argument("--interval", type=int, default=60)
    a = ap.parse_args()

    p = pid()
    if not p:
        sys.exit("AgentIsland is not running")

    first = sample(p)
    base_lat = len(latencies(0))
    print(f"  soaking {a.minutes:.0f} min, sampling every {a.interval}s")
    print(f"  start: {first['rss']:.1f} MB, {first['fds']} fds")

    end = time.time() + a.minutes * 60
    prev, marks = first, []
    while time.time() < end:
        time.sleep(a.interval)
        s = sample(p)
        if s is None:
            print("  ! process exited during soak")
            sys.exit(1)
        cpu_pct = (s["cpu"] - prev["cpu"]) / a.interval * 100
        marks.append((s["rss"], s["fds"], cpu_pct))
        prev = s
        print(f"    {time.strftime('%H:%M:%S')}  {s['rss']:6.1f} MB  {s['fds']:4} fds  {cpu_pct:5.2f}% cpu")

    lat = latencies(base_lat)
    rss0, rssN = first["rss"], marks[-1][0]
    fd0, fdN = first["fds"], marks[-1][1]
    print(f"\n  memory  {rss0:.1f} -> {rssN:.1f} MB   drift {rssN - rss0:+.1f} MB")
    print(f"  handles {fd0} -> {fdN}          drift {fdN - fd0:+d}")
    print(f"  cpu     mean {sum(m[2] for m in marks)/len(marks):.2f}%   max {max(m[2] for m in marks):.2f}%")
    if lat:
        print(f"  discovery  mean {sum(lat)/len(lat):.2f}s   max {max(lat):.2f}s   n={len(lat)}")

    fails = []
    if rssN - rss0 > 15:
        fails.append(f"memory grew {rssN - rss0:.1f} MB")
    if fdN - fd0 > 40:
        fails.append(f"file handles grew {fdN - fd0}")
    if lat and sum(lat) / len(lat) > 1.0:
        fails.append(f"discovery mean {sum(lat)/len(lat):.2f}s over 1s budget")
    print("\n  " + ("SOAK PASS" if not fails else "SOAK FAIL: " + "; ".join(fails)))
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
