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
try:
    WINDOW = float(os.environ.get("AGENTISLAND_Q_TIMEOUT", "300"))
except ValueError:
    WINDOW = 300.0


def _island_alive():
    """The app's own heartbeat, on a timer of its own and independent of any one card."""
    try:
        return time.time() - os.path.getmtime(ALIVE) < 15
    except OSError:
        return False


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
                # How long this hook will actually wait, so the island never offers an answer
                # to something that has stopped listening, or withdraws one too early.
                "expires_at": time.time() + WINDOW,
                "items": items,
            }) + "\n")
    except OSError:
        bail()

    path = os.path.join(DECISIONS, req_id)
    skip = path + ".skip"
    # Wait the window out flat. This used to hold only while the island kept re-touching a
    # per-card heartbeat file, so one missed 10s window killed the hook mid-answer — and a
    # Timer in the default run-loop mode is suspended for exactly as long as AppKit tracks
    # the mouse, which is precisely when someone is using the card. Three answers died that
    # way. The app's own heartbeat already covers what the per-card one was for.
    started = time.time()
    while time.time() - started < WINDOW:
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
            # that were asked, in the shape each one allows, with only offered labels — or
            # text the reader typed, which the island marks so a mistyped label cannot pass
            # for one.
            def typed(v):
                if not (isinstance(v, dict) and set(v) == {"other"}):
                    return None
                t = v["other"]
                if not isinstance(t, str):
                    return None
                t = "".join(c for c in t if c.isprintable()).strip()
                return t[:2000] or None

            def one(w, labels):
                if isinstance(w, str):
                    return w if w in labels else None
                return typed(w)

            answers = {}
            for item in items:
                want = picked.get(item["question"])
                labels = [o["label"] for o in item["options"]]
                if item["multi"]:
                    if not isinstance(want, list) or not want:
                        bail()
                    seen = [w for i, w in enumerate(want) if w not in want[:i]]
                    got = [one(w, labels) for w in seen]
                    if any(g is None for g in got):
                        bail()
                    answers[item["question"]] = got
                else:
                    got = one(want, labels)
                    if got is None:
                        bail()
                    answers[item["question"]] = got
            updated = dict(tool_input)
            updated["answers"] = answers
            print(json.dumps({"hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "allow",
                "permissionDecisionReason": f"AgentIsland: answered {len(answers)} question(s) from the notch",
                "updatedInput": updated,
            }}))
            sys.exit(0)
        # The reader chose to answer in the terminal. Stand down now: Claude cannot show its
        # own picker while this hook is still holding the turn.
        if os.path.exists(skip):
            break
        # The island going away is the one thing that should end the wait early.
        if not _island_alive():
            break
        time.sleep(0.12)
    try:
        os.remove(skip)
    except OSError:
        pass
    bail()   # timed out, or handed over — Claude asks normally


if __name__ == "__main__":
    main()
