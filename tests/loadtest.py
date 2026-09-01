#!/usr/bin/env python3
"""Does discovery stay cheap when a hundred agents are running?

The panel is most useful exactly when the machine is busiest, so the cost of looking has to be
flat in the number of sessions. This builds a synthetic fleet in a throwaway HOME and measures
the real discovery path against it — the same code the app runs, not a model of it.

AGENTISLAND_HOME is the whole trick: it points discovery at the fixture, so nothing synthetic can
ever reach the real panel. (Plain $HOME does not work — NSHomeDirectory reads the password
database and ignores it, which meant the first version of this test silently measured the real
machine and reported a flat line for every fleet size.)

  python3 tests/loadtest.py                  # 10, 50, 100, 200 sessions
  python3 tests/loadtest.py --sizes 100
"""
import argparse, json, os, re, shutil, subprocess, sys, tempfile, time, uuid

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.path.join(REPO, ".build/release/AgentIsland")

# Codex embeds its instructions in session_meta; that line is ~22KB on this machine and was the
# cause of a real bug, so the fixture reproduces it rather than writing a tidy little one.
FILLER = "x" * 21000


def codex_session(root, i, now):
    day = os.path.join(root, ".codex/sessions/2026/09/01")
    os.makedirs(day, exist_ok=True)
    sid = f"{uuid.uuid4()}"
    path = os.path.join(day, f"rollout-2026-09-01T00-00-{i % 60:02d}-{sid}.jsonl")
    cwd = os.path.join(root, "work")
    os.makedirs(cwd, exist_ok=True)
    with open(path, "w") as f:
        f.write(json.dumps({"type": "session_meta",
                            "payload": {"id": sid, "cwd": cwd, "instructions": FILLER}}) + "\n")
        for turn in range(12):
            f.write(json.dumps({"type": "response_item",
                                "payload": {"type": "message", "role": "user",
                                            "content": [{"type": "input_text",
                                                         "text": f"synthetic load turn {turn}"}]}}) + "\n")
            f.write(json.dumps({"type": "event_msg",
                                "payload": {"type": "token_count",
                                            "info": {"last_token_usage": {"input_tokens": 40000 + turn},
                                                     "total_token_usage": {"input_tokens": 900000},
                                                     "model_context_window": 258400}}}) + "\n")
            f.write(json.dumps({"type": "response_item",
                                "payload": {"type": "function_call_output",
                                            "output": "y" * 4000}}) + "\n")
    os.utime(path, (now, now))
    return sid


def cursor_session(root, i, now):
    sid = str(uuid.uuid4())
    chat = os.path.join(root, ".cursor/chats", f"{i:032x}"[:32], sid)
    os.makedirs(chat, exist_ok=True)
    cwd = os.path.join(root, "work")
    os.makedirs(cwd, exist_ok=True)
    json.dump({"cwd": cwd, "hasConversation": True, "schemaVersion": 1,
               "createdAtMs": int(now * 1000), "updatedAtMs": int(now * 1000)},
              open(os.path.join(chat, "meta.json"), "w"))
    # Only sessions a person started are shown, so the fixture must look like one.
    json.dump([f"synthetic load prompt {i}"], open(os.path.join(chat, "prompt_history.json"), "w"))
    open(os.path.join(chat, "store.db"), "w").close()

    tdir = os.path.join(root, ".cursor/projects/loadtest/agent-transcripts", sid)
    os.makedirs(tdir, exist_ok=True)
    tpath = os.path.join(tdir, f"{sid}.jsonl")
    with open(tpath, "w") as f:
        for turn in range(20):
            f.write(json.dumps({"type": "message", "role": "user",
                                "content": [{"type": "text",
                                             "text": f"<user_query>\nsynthetic turn {turn}\n</user_query>"}]}) + "\n")
            f.write(json.dumps({"type": "assistant", "content": "z" * 3000}) + "\n")
        f.write(json.dumps({"type": "turn_ended", "status": "success"}) + "\n")
    os.utime(tpath, (now, now))
    os.utime(chat, (now, now))
    return sid


def build_fixture(n, now):
    root = tempfile.mkdtemp(prefix="ai-load-")
    per = max(1, n // 2)
    for i in range(per):
        codex_session(root, i, now)
    for i in range(n - per):
        cursor_session(root, i, now)
    size = subprocess.run(["du", "-sh", root], capture_output=True, text=True).stdout.split()[0]
    return root, size


def measure(root, runs=4):
    env = dict(os.environ, AGENTISLAND_HOME=root)
    r = subprocess.run([BIN, "--benchmark-discovery", str(runs)],
                       capture_output=True, text=True, env=env)
    warm = []
    for line in r.stdout.splitlines()[1:]:          # drop run 1: cold caches
        m = re.search(r"total ([\d.]+)s\s+(\d+) spawns", line)
        if m:
            warm.append((float(m.group(1)), int(m.group(2))))
    counts = {}
    for vendor in ("codex", "cursor"):
        m = re.search(rf"{vendor} (\d+)/", r.stdout)
        if m:
            counts[vendor] = int(m.group(1))
    if not warm:
        print(r.stdout, r.stderr)
        return None
    return {"secs": sum(w[0] for w in warm) / len(warm),
            "spawns": max(w[1] for w in warm), "found": counts}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sizes", type=int, nargs="+", default=[10, 50, 100, 200])
    args = ap.parse_args()
    if not os.path.exists(BIN):
        sys.exit("build first: swift build -c release")

    now = time.time()
    print("  fleet   rows shown   on disk    warm discovery   spawns   per session")
    rows = []
    for n in args.sizes:
        root, size = build_fixture(n, now)
        try:
            r = measure(root)
        finally:
            shutil.rmtree(root, ignore_errors=True)
        if not r:
            continue
        found = r["found"].get("codex", 0) + r["found"].get("cursor", 0)
        # Cost per session on disk, not per row shown: Cursor deliberately caps its row count,
        # and the scan still pays for every chat directory it walks past.
        per_ms = 1000.0 * r["secs"] / n
        rows.append((n, found, r["secs"], r["spawns"], per_ms))
        print(f"  {n:>5}   {found:>10}   {size:>7}   {r['secs']:>8.3f}s      "
              f"{r['spawns']:>3}    {per_ms:>6.1f} ms")

    if len(rows) >= 2:
        first, last = rows[0], rows[-1]
        print(f"\n  sessions ×{last[0] / max(first[0], 1):.0f}  →  "
              f"discovery ×{last[2] / max(first[2], 1e-6):.1f},  "
              f"spawns {first[3]} → {last[3]}")
        # The failure this guards against is per-agent work: a spawn count that climbs with the
        # fleet, or a per-session cost that does not fall as the fixed cost is amortised.
        flat_spawns = last[3] <= first[3] + 2
        print(f"  spawn count independent of fleet size: {'yes' if flat_spawns else 'NO'}")
        ok = flat_spawns and last[2] < 6.0
        print("\n  LOAD PASS" if ok else "\n  LOAD FAIL")
        return 0 if ok else 1
    return 1


if __name__ == "__main__":
    sys.exit(main())
