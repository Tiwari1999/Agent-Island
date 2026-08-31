#!/usr/bin/env python3
"""Auto-approve rules, consulted before the island is asked.

Rules live in ~/.agentisland/rules.json:
  [{"tool":"Bash","pattern":"^npm (test|run build)\\\\b","cwd":"/Users/me/repo","action":"allow"}]

`tool` and `cwd` are optional; `pattern` is a regex matched against the command or file path.
Anything that does not match falls through untouched, so the island (or Claude) still asks.
"""
import json, os, re, sys

RULES = os.environ.get("AGENTISLAND_RULES",
                       os.path.expanduser("~/.agentisland/rules.json"))


def subject(tool, inp):
    """The text a rule matches against, per tool."""
    if tool == "Bash":
        return inp.get("command", "")
    if tool in ("Read", "Edit", "Write", "NotebookEdit"):
        return inp.get("file_path", "")
    if tool == "Grep":
        return inp.get("pattern", "")
    return json.dumps(inp)


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        sys.exit(0)
    try:
        rules = json.load(open(RULES))
    except Exception:
        sys.exit(0)          # no rules file is the normal case
    if not isinstance(rules, list):
        sys.exit(0)

    tool = payload.get("tool_name", "")
    inp = payload.get("tool_input") or {}
    cwd = payload.get("cwd", "")
    text = subject(tool, inp)

    for r in rules:
        if not isinstance(r, dict):
            continue
        if r.get("tool") and r["tool"] != tool:
            continue
        if r.get("cwd") and not cwd.startswith(r["cwd"]):
            continue
        pat = r.get("pattern")
        if not pat:
            continue
        try:
            if not re.search(pat, text):
                continue
        except re.error:
            continue          # a broken rule must never block a session
        action = r.get("action", "allow")
        if action not in ("allow", "deny"):
            continue
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "PermissionRequest",
            "permissionDecision": action,
            "permissionDecisionReason": f"AgentIsland rule: {pat}",
        }}))
        sys.exit(0)
    sys.exit(0)


if __name__ == "__main__":
    main()
