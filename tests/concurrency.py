#!/usr/bin/env python3
"""Several agents blocking at once.

With ten agents running, two hitting a permission prompt in the same second is ordinary. Each
must get its own decision — a crossed wire would approve one agent's command by answering a
different agent's prompt, which is the worst failure this app could have.
"""
import json, os, subprocess, sys, tempfile, threading, time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PERM = f"{REPO}/hooks/agentisland-permission.sh"
N = 8


def main():
    work = tempfile.mkdtemp(prefix="conc-")
    spool, decisions = f"{work}/spool.jsonl", f"{work}/decisions"
    alive = f"{work}/alive"
    os.makedirs(decisions)
    open(alive, "w").close()
    env = dict(os.environ, AGENTISLAND_SPOOL=spool, AGENTISLAND_DECISIONS=decisions,
               AGENTISLAND_ALIVE=alive, AGENTISLAND_TIMEOUT_TENTHS="200")

    results = {}

    def fire(i):
        payload = json.dumps({"session_id": f"agent-{i:02d}", "hook_event_name": "PermissionRequest",
                              "tool_name": "Bash", "tool_input": {"command": f"deploy-service-{i:02d}"}})
        p = subprocess.run([PERM], input=payload.encode(), capture_output=True, env=env, timeout=30)
        results[i] = p.stdout.decode()

    threads = [threading.Thread(target=fire, args=(i,)) for i in range(N)]
    for t in threads:
        t.start()

    # Wait for every request to be published, then answer them in a deliberately shuffled order.
    deadline = time.time() + 10
    published = {}
    while time.time() < deadline and len(published) < N:
        try:
            for line in open(spool):
                obj = json.loads(line)
                published[obj["payload"]["session_id"]] = obj["ap_request_id"]
        except (FileNotFoundError, json.JSONDecodeError, KeyError):
            pass
        time.sleep(0.1)

    print(f"  {len(published)}/{N} requests published concurrently")
    if len(published) < N:
        print("  FAIL: not every concurrent request was published")
        sys.exit(1)

    # Answer in reverse, and alternate allow/deny, so a crossed wire cannot hide behind ordering.
    want = {}
    for idx, (sid, rid) in enumerate(sorted(published.items(), reverse=True)):
        decision = "allow" if idx % 2 == 0 else "deny"
        want[sid] = decision
        open(f"{decisions}/{rid}", "w").write(decision)

    for t in threads:
        t.join(timeout=30)

    bad = 0
    for i in range(N):
        sid = f"agent-{i:02d}"
        out = results.get(i, "")
        try:
            got = json.loads(out)["hookSpecificOutput"]["permissionDecision"]
        except Exception:
            got = "none"
        ok = got == want[sid]
        bad += not ok
        print(f"  {'PASS' if ok else 'FAIL'}  {sid}  wanted {want[sid]:5}  got {got}")

    leftover = os.listdir(decisions)
    print(f"\n  decision files left behind: {len(leftover)} (each must be consumed)")
    print("  " + ("CONCURRENCY PASS" if bad == 0 and not leftover
                  else f"CONCURRENCY FAIL: {bad} mismatched, {len(leftover)} leaked"))
    sys.exit(1 if bad or leftover else 0)


if __name__ == "__main__":
    main()
