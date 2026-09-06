#!/usr/bin/env python3
"""Answer an AskUserQuestion from the notch.

PreToolUse is the only hook that may return `updatedInput`, and AskUserQuestion carries an
`answers` field the permission UI normally fills in — so injecting the user's pick there and
allowing the call is how a one-click answer reaches Claude.

Every failure path exits 0 silently, which leaves Claude's own question prompt untouched.
"""
import json, os, sys, time

os.umask(0o077)   # answers and spool lines are private

SPOOL = os.environ.get("AGENTISLAND_SPOOL", "/tmp/agentisland-events.jsonl")
DECISIONS = os.environ.get("AGENTISLAND_DECISIONS", "/tmp/agentisland-decisions")
ALIVE = os.environ.get("AGENTISLAND_ALIVE", "/tmp/agentisland.alive")
TIMEOUT = float(os.environ.get("AGENTISLAND_Q_TIMEOUT", "45"))


def bail():
    sys.exit(0)


def _held(hold, started, hard):
    """A hold refreshed in the last 10s extends the wait, up to an absolute ceiling."""
    if time.time() - started > hard:
        return False
    try:
        return time.time() - os.path.getmtime(hold) < 10
    except OSError:
        return False


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
    if not isinstance(questions, list) or not questions:
        bail()

    # Every option carries a description and often a preview; forwarding only labels left the
    # card asking people to choose between words with no reasoning attached.
    def one(q):
        if not isinstance(q, dict):
            return None
        raw = q.get("options")
        if not isinstance(raw, list):
            return None
        opts = []
        for o in raw:
            if not isinstance(o, dict) or not o.get("label"):
                continue
            opts.append({
                "label": o["label"],
                "description": o.get("description", "") or "",
                "preview": o.get("preview", "") or "",
            })
        if not opts:
            return None
        return {
            "question": q.get("question", ""),
            "header": q.get("header", ""),
            "multi": bool(q.get("multiSelect")),
            "options": opts,
        }

    items = [i for i in (one(q) for q in questions) if i]
    if len(items) != len(questions):
        bail()      # one unreadable question means the whole ask belongs in the terminal

    req_id = f"aq-{os.getpid()}-{int(time.time())}"
    try:
        # Answers are private: the default mode leaves them readable by every user on the box.
        os.makedirs(DECISIONS, mode=0o700, exist_ok=True)
        os.chmod(DECISIONS, 0o700)
    except OSError:
        bail()
    try:
        with open(SPOOL, "a") as f:
            f.write(json.dumps({
                "ap_question_id": req_id,
                "session_id": payload.get("session_id", ""),
                "cwd": payload.get("cwd", ""),
                "items": items,
            }) + "\n")
    except OSError:
        bail()

    path = os.path.join(DECISIONS, req_id)
    hold = path + ".hold"
    # The island refreshes <id>.hold while the card is on screen. Without this the question
    # expired after TIMEOUT even with the user mid-read, and the card simply vanished.
    try:
        HARD = float(os.environ.get("AGENTISLAND_Q_HOLD_HARD", "300"))
    except ValueError:
        HARD = 300.0
    started = time.time()
    deadline = started + TIMEOUT
    while time.time() < deadline or _held(hold, started, HARD):
        if os.path.exists(path):
            try:
                choice = open(path).read().strip()
                os.remove(path)
            except OSError:
                bail()
            # One JSON object mapping each question to its chosen label, so a four-question
            # ask comes back in one write instead of four round trips.
            try:
                picked = json.loads(choice)
            except Exception:
                bail()
            if not isinstance(picked, dict) or not picked:
                bail()
            # Rebuild rather than pass through: an answer must contain exactly the questions
            # that were asked, in the shape each one allows, with only offered labels.
            answers = {}
            for item in items:
                want = picked.get(item["question"])
                labels = [o["label"] for o in item["options"]]
                if item["multi"]:
                    if not isinstance(want, list) or not want:
                        bail()
                    seen = [w for i, w in enumerate(want) if w not in want[:i]]
                    if any(w not in labels for w in seen):
                        bail()
                    answers[item["question"]] = seen
                else:
                    if not isinstance(want, str) or want not in labels:
                        bail()
                    answers[item["question"]] = want
            updated = dict(tool_input)
            updated["answers"] = answers
            print(json.dumps({"hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "allow",
                "permissionDecisionReason": f"AgentIsland: answered {len(answers)} question(s) from the notch",
                "updatedInput": updated,
            }}))
            sys.exit(0)
        time.sleep(0.12)
    try:
        os.remove(hold)
    except OSError:
        pass
    bail()   # timed out — Claude asks normally


if __name__ == "__main__":
    main()
