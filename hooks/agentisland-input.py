#!/usr/bin/env python3
"""Deliver a reply typed in the notch to a session no terminal will let us write to.

iTerm, Terminal, tmux, kitty and WezTerm all publish a way to put a line into a running session,
so `TerminalWrite` uses it. Warp publishes none, and macOS refuses TIOCSTI, so there is no way to
reach that session from outside at all — except through Claude Code itself.

A Stop hook may answer `{"decision": "block", "reason": ...}`, which keeps the turn going and
hands the reason to the model. So the island leaves the line in a file and this picks it up the
moment the agent finishes what it was doing. That is a queued steer, not live typing: an agent
already sitting idle has no turn left to end, which is why the island only offers this while a
session is working.

Every failure path exits 0 printing nothing, which leaves the agent to stop exactly as it would
have without us.
"""
import json
import os
import sys

QUEUE = os.environ.get("AGENTISLAND_INPUT", "/tmp/agentisland-input")
LIMIT = 4096


def main():
    try:
        event = json.loads(sys.stdin.read() or "{}")
    except Exception:
        return
    session = event.get("session_id") or ""
    # The id is interpolated into a path, and it comes from the agent rather than from us.
    if not session or not all(c.isalnum() or c in "-_" for c in session):
        return

    path = os.path.join(QUEUE, session)
    try:
        with open(path) as f:
            message = f.read()
    except OSError:
        return
    # Removed before it is acted on: a message delivered twice is worse than one lost, and a
    # crash between here and the print would otherwise repeat on every turn for ever.
    try:
        os.remove(path)
    except OSError:
        pass

    message = message.strip()[:LIMIT]
    if message:
        print(json.dumps({"decision": "block", "reason": message}))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
