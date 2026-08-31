#!/usr/bin/env python3
"""Remove synthetic events from the live spool.

Test and benchmark traffic used to share the spool the app reads, so a `bench-00` row could
appear in the panel beside real sessions. The generators now write elsewhere; this cleans up
anything left behind, and is safe to run at any time.
"""
import json, os, re, sys

SPOOL = "/tmp/agentisland-events.jsonl"
# A real session id is a UUID. Anything short and prefixed is ours.
SYNTHETIC = re.compile(r"^(bench-|selftest|probe-|aq-|ap-)")


def main():
    if not os.path.exists(SPOOL):
        print("  no spool, nothing to do")
        return
    kept, dropped = [], 0
    with open(SPOOL) as f:
        for line in f:
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                dropped += 1          # unparseable lines are not real events either
                continue
            payload = obj.get("payload", obj)
            sid = str(payload.get("session_id", ""))
            if SYNTHETIC.match(sid) or (len(sid) < 20 and sid and "-" not in sid):
                dropped += 1
                continue
            kept.append(line)
    with open(SPOOL, "w") as f:
        f.writelines(kept)
    print(f"  removed {dropped} synthetic events, kept {len(kept)}")


if __name__ == "__main__":
    main()
