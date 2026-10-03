#!/usr/bin/env python3
"""Runs on a REMOTE host over `ssh host python3 -` and reports its agent sessions as JSON.

Self-contained stdlib-only on purpose: nothing is installed on the remote, nothing is left
behind, and the same file doubles as the fixture-testable half of SSH monitoring. Reads the
same on-disk state the local sources do — Claude transcripts and Codex rollouts — plus which
processes are alive, and prints one JSON array on stdout.

Tunables come in as env vars (AGENTISLAND_PROBE_ROOT / _DAYS / _MAX) since stdin is the script.
"""
import glob, json, os, re, sqlite3, subprocess, sys, time

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


def running(names, flag="-x"):
    """pid -> cwd for the given process names; /proc on Linux, lsof elsewhere."""
    out = {}
    all_pids = []
    for name in names:
        r = subprocess.run(["pgrep", flag, name], capture_output=True, text=True).stdout
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
    if flag == "-f":   # a command-line match also finds a relaunching CLI's wrapper; one per cwd
        out = {p: c for c, p in {c: p for p, c in sorted(out.items())}.items()}
    return out


def custom_title(path, t):
    # A /rename beats the generated title; Claude also keeps it beside the transcript.
    v = last_value("customTitle", t)
    if v:
        return v
    try:
        with open(os.path.join(path[:-6], "custom-title.json")) as f:
            return json.load(f).get("customTitle") or None
    except (OSError, ValueError):
        return None


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
            "title": custom_title(path, t) or last_value("aiTitle", t),
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


def gemini_sessions():
    # ~/.gemini/tmp/<project>/chats/session-*.jsonl; the project's directory is in .project_root.
    out = []
    for path in glob.glob(os.path.join(ROOT, ".gemini/tmp/*/chats/session-*.jsonl")):
        mtime = os.path.getmtime(path)
        if NOW - mtime > DAYS * 86400:
            continue
        try:
            with open(path, errors="replace") as f:
                meta = json.loads(f.readline())
            cwd = open(os.path.join(os.path.dirname(os.path.dirname(path)), ".project_root")).read().strip()
        except (OSError, ValueError):
            continue
        if meta.get("kind") == "subagent":
            continue
        typed = []
        for line in tail(path).splitlines():
            if '"type":"user"' not in line:
                continue
            try:
                o = json.loads(line)
            except ValueError:
                continue
            # What was typed beats the expansion; tool results carry no text part at all.
            parts = o.get("displayContent") or o.get("content")
            text = parts if isinstance(parts, str) else "".join(
                p.get("text", "") for p in parts or [] if isinstance(p, dict))
            if text.strip():
                typed.append(text.strip().split("\n")[0])
        out.append({"vendor": "gemini", "sessionId": meta.get("sessionId"), "cwd": cwd,
                    "title": typed[0][:120] if typed else None,
                    "prompt": typed[-1][:120] if typed else None,
                    "lastActive": iso(mtime), "mtime": mtime})
    return out


def opencode_sessions():
    db = os.path.join(ROOT, ".local/share/opencode/opencode.db")
    if not os.path.exists(db):
        return []
    try:
        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=0.2)
        rows = con.execute("SELECT id, directory, title, time_updated FROM session "
                           "WHERE parent_id IS NULL AND time_archived IS NULL AND time_updated > ?",
                           (int((NOW - DAYS * 86400) * 1000),)).fetchall()
        con.close()
    except sqlite3.Error:
        return []
    return [{"vendor": "opencode", "sessionId": i, "cwd": d,
             "title": None if t.startswith("New session - ") else t, "prompt": None,
             "lastActive": iso(u / 1000), "mtime": u / 1000} for i, d, t, u in rows]


def iso(ts):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(ts))


def main():
    sessions = claude_sessions() + codex_sessions() + gemini_sessions() + opencode_sessions()
    sessions.sort(key=lambda s: s["mtime"], reverse=True)
    sessions = sessions[:MAX]

    # Gemini is a Node script, so its process is only findable by command line.
    live = {"claude": running(["claude"]), "codex": running(["codex"]),
            "gemini": running(["/gemini( |$)"], "-f"), "opencode": running(["opencode"])}
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
