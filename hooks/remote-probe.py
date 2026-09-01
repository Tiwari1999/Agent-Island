#!/usr/bin/env python3
"""Runs on a REMOTE host over `ssh host python3 -` and reports its agent sessions as JSON.

Self-contained stdlib-only on purpose: nothing is installed on the remote, nothing is left
behind, and the same file doubles as the fixture-testable half of SSH monitoring. Reads the
same on-disk state the local sources do — Claude transcripts and Codex rollouts — plus which
processes are alive, and prints one JSON array on stdout.

Tunables come in as env vars (AGENTISLAND_PROBE_ROOT / _DAYS / _MAX) since stdin is the script.
"""
import glob, json, os, re, subprocess, sys, time

ROOT = os.environ.get("AGENTISLAND_PROBE_ROOT", os.path.expanduser("~"))
DAYS = float(os.environ.get("AGENTISLAND_PROBE_DAYS", "10"))
MAX = int(os.environ.get("AGENTISLAND_PROBE_MAX", "20"))
NOW = time.time()


def tail(path, size=65536):
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            end = f.tell()
            f.seek(max(0, end - size))
            return f.read().decode("utf8", "replace")
    except OSError:
        return ""


def last_value(key, text):
    # Tolerates pretty-printed JSON; today's transcripts are compact but that is not a contract.
    hits = re.findall(r'"%s"\s*:\s*"([^"]*)"' % re.escape(key), text)
    return hits[-1] if hits else None


def running(names):
    """pid -> cwd for the given process names; /proc on Linux, lsof elsewhere."""
    out = {}
    all_pids = []
    for name in names:
        r = subprocess.run(["pgrep", "-x", name], capture_output=True, text=True).stdout
        all_pids += [p for p in r.split() if p.isdigit()]
    for p in all_pids:
        cwd = None
        proc = "/proc/%s/cwd" % p
        if os.path.exists(proc):
            try:
                cwd = os.readlink(proc)
            except OSError:
                pass
        else:  # macOS remote: fall back to lsof
            r = subprocess.run(["lsof", "-a", "-p", p, "-d", "cwd", "-Fn"],
                               capture_output=True, text=True).stdout
            for line in r.splitlines():
                if line.startswith("n"):
                    cwd = line[1:]
        if cwd:
            out[int(p)] = cwd
    return out


def claude_sessions():
    out = []
    for path in glob.glob(os.path.join(ROOT, ".claude/projects/*/*.jsonl")):
        mtime = os.path.getmtime(path)
        if NOW - mtime > DAYS * 86400:
            continue
        t = tail(path)
        cwd = last_value("cwd", t)
        out.append({
            "vendor": "claude",
            "sessionId": os.path.basename(path)[:-6],
            "cwd": cwd,
            "title": last_value("aiTitle", t),
            "prompt": (last_value("lastPrompt", t) or "").split("\\n")[0][:120] or None,
            "lastActive": last_value("timestamp", t) or iso(mtime),
            "mtime": mtime,
        })
    return out


def codex_sessions():
    out = []
    for path in glob.glob(os.path.join(ROOT, ".codex/sessions/*/*/*/rollout-*.jsonl")):
        mtime = os.path.getmtime(path)
        if NOW - mtime > DAYS * 86400:
            continue
        try:
            with open(path, errors="replace") as f:
                meta = json.loads(f.readline())
        except (OSError, ValueError):
            continue
        if meta.get("type") != "session_meta":
            continue
        pay = meta.get("payload", {})
        t = tail(path)
        first = None
        m = re.search(r'"text":"([^"<][^"]{0,200})"', t)
        if m:
            first = m.group(1)[:120]
        out.append({
            "vendor": "codex",
            "sessionId": pay.get("id"),
            "cwd": pay.get("cwd"),
            "title": first,
            "prompt": first,
            "lastActive": iso(mtime),
            "mtime": mtime,
        })
    return out


def iso(ts):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(ts))


def main():
    sessions = claude_sessions() + codex_sessions()
    sessions.sort(key=lambda s: s["mtime"], reverse=True)
    sessions = sessions[:MAX]

    live = {"claude": running(["claude"]), "codex": running(["codex"])}
    # A pid can only be claimed once, by the freshest session in its directory — several
    # sessions sharing a cwd cannot be told apart, and the local app refuses to guess too.
    for s in sessions:
        pids = live.get(s["vendor"], {})
        pid = next((p for p, c in pids.items() if c == s["cwd"]), None)
        if pid is not None:
            del pids[pid]
        s["pid"] = pid
        s["state"] = "busy" if pid and NOW - s["mtime"] < 120 else ("idle" if pid else None)
        del s["mtime"]

    json.dump(sessions, sys.stdout)


if __name__ == "__main__":
    main()
