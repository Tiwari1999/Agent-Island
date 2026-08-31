#!/usr/bin/env python3
"""Answer an AskUserQuestion from the notch.

PreToolUse is the only hook that may return `updatedInput`, and AskUserQuestion carries an
`answers` field the permission UI normally fills in — so injecting the user's pick there and
allowing the call is how a one-click answer reaches Claude.

Every failure path exits 0 silently, which leaves Claude's own question prompt untouched.
"""
import json, os, sys, time

SPOOL = os.environ.get("AGENTISLAND_SPOOL", "/tmp/agentisland-events.jsonl")
DECISIONS = os.environ.get("AGENTISLAND_DECISIONS", "/tmp/agentisland-decisions")
ALIVE = os.environ.get("AGENTISLAND_ALIVE", "/tmp/agentisland.alive")
TIMEOUT = float(os.environ.get("AGENTISLAND_Q_TIMEOUT", "45"))


def bail():
    sys.exit(0)


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        bail()

    # Valid JSON is not necessarily an object. A list or a bare string here used to raise on
    # .get() and exit non-zero, which an agent may read as a hook failure.
    if not isinstance(payload, dict):
        bail()

    if payload.get("tool_name") != "AskUserQuestion":
        bail()

    # Nobody home, or a stale heartbeat: let Claude ask in the terminal as usual.
    try:
        if time.time() - os.path.getmtime(ALIVE) > 15:
            bail()
    except OSError:
        bail()

    tool_input = payload.get("tool_input")
    if not isinstance(tool_input, dict):
        bail()
    questions = tool_input.get("questions")
    if not isinstance(questions, list):
        bail()
    # Multi-question prompts need a sequence the notch cannot express yet; defer to Claude.
    if len(questions) != 1:
        bail()

    q = questions[0]
    if not isinstance(q, dict):
        bail()
    options = [o.get("label", "") for o in (q.get("options") or [])
               if isinstance(o, dict) and o.get("label")]
    if not options:
        bail()

    req_id = f"aq-{os.getpid()}-{int(time.time())}"
    os.makedirs(DECISIONS, exist_ok=True)
    try:
        with open(SPOOL, "a") as f:
            f.write(json.dumps({
                "ap_question_id": req_id,
                "session_id": payload.get("session_id", ""),
                "question": q.get("question", ""),
                "header": q.get("header", ""),
                "options": options,
                "multi": bool(q.get("multiSelect")),
            }) + "\n")
    except OSError:
        bail()

    path = os.path.join(DECISIONS, req_id)
    deadline = time.time() + TIMEOUT
    while time.time() < deadline:
        if os.path.exists(path):
            try:
                choice = open(path).read().strip()
                os.remove(path)
            except OSError:
                bail()
            if not choice or choice not in options:
                bail()
            updated = dict(tool_input)
            updated["answers"] = {q.get("question", ""): choice}
            print(json.dumps({"hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "allow",
                "permissionDecisionReason": f"AgentIsland: user chose {choice}",
                "updatedInput": updated,
            }}))
            sys.exit(0)
        time.sleep(0.12)
    bail()   # timed out — Claude asks normally


if __name__ == "__main__":
    main()
