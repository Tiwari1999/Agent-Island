#!/usr/bin/env python3
"""Auto-approve rules, consulted before the island is asked.

Rules live in ~/.agentisland/rules.json:
  [{"tool":"Bash","pattern":"^npm (test|run build)\\\\b","cwd":"/Users/me/repo","action":"allow"}]

`tool` and `cwd` are optional; `pattern` is a regex matched against the command or file path.
Anything that does not match falls through untouched, so the island (or Claude) still asks.

Two limits an allow rule cannot escape, because an agent that can write files can write this
one: the pattern must name what it allows (a catch-all is refused), and no rule may approve a
command the island itself considers destructive. Deny rules are unrestricted. The file is
ignored entirely if it is a symlink, not yours, or writable by anyone else, and every
automatic decision is written to the log.
"""
import json, os, re, stat, sys

RULES = os.environ.get("AGENTISLAND_RULES",
                       os.path.expanduser("~/.agentisland/rules.json"))
LOG = os.environ.get("AGENTISLAND_LOG", "/tmp/agentisland.log")

# An agent can write files. That means a prompt injection can write THIS file, and a rule of
# ".*" would auto-approve everything before the user is ever shown a card. Two independent
# defences below: a rule may never be broad, and it may never allow a command that the island
# itself would flag as dangerous. A compromised rules file then buys an attacker nothing that
# the user would not have been asked about anyway.
NEVER_AUTO = [
    "rm -rf", "rm -r ", "sudo ", "--force", "-f ", "git push", "git reset --hard",
    "drop table", "drop database", "truncate ", "delete from", "kubectl delete",
    "terraform destroy", "> /dev/", "chmod 777", ":(){ :|:& };:", "mkfs",
    "curl ", "wget ", "shutdown", "diskutil", "launchctl", "csrutil",
]
# Any string a real command would never contain; a pattern that matches this matches anything.
SENTINEL = "zqx-agentisland-breadth-probe-8f3a1c-\u2603-/dev/null"


def too_broad(pattern):
    """A rule must name what it allows. '.*' and friends match the probe; real patterns do not."""
    try:
        return re.search(pattern, SENTINEL) is not None
    except re.error:
        return True


def rules_file_is_safe(path):
    """Refuse a rules file anyone else could have written, or a symlink pointing elsewhere."""
    try:
        st = os.lstat(path)
    except OSError:
        return False
    if stat.S_ISLNK(st.st_mode):
        return False
    if st.st_uid != os.getuid():
        return False
    return not (st.st_mode & (stat.S_IWGRP | stat.S_IWOTH))


def note(line):
    try:
        with open(LOG, "a") as f:
            f.write(line + "\n")
    except OSError:
        pass


def subject(tool, inp):
    """The text a rule matches against, per tool.

    Vendors name the same tool differently — Claude's Bash is Cursor's Shell — so one rule set
    can govern every agent only if the names are folded together here.
    """
    if tool in ("Bash", "Shell", "run_terminal_cmd"):
        return inp.get("command") or inp.get("cmd") or ""
    if tool in ("Read", "Edit", "Write", "NotebookEdit", "read_file", "edit_file"):
        return inp.get("file_path") or inp.get("path") or ""
    if tool == "Grep":
        return inp.get("pattern", "")
    return json.dumps(inp)


ALIASES = [{"Bash", "Shell", "run_terminal_cmd"},
           {"Read", "read_file"},
           {"Edit", "Write", "edit_file"}]


def _same_tool(a, b):
    return any(a in group and b in group for group in ALIASES)


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        sys.exit(0)
    # Valid JSON need not be an object; a list would raise on .get() below.
    if not isinstance(payload, dict):
        sys.exit(0)
    if not rules_file_is_safe(RULES):
        sys.exit(0)          # missing is the normal case; unsafe is a refusal
    try:
        rules = json.load(open(RULES))
    except Exception:
        sys.exit(0)
    if not isinstance(rules, list):
        sys.exit(0)

    # Cursor sends camelCase event names; the rule file should not have to know that.
    tool = payload.get("tool_name") or payload.get("toolName") or ""
    # A question is answered by its card, never allowed or denied by a rule.
    if tool == "AskUserQuestion":
        sys.exit(0)
    inp = payload.get("tool_input") or {}
    cwd = payload.get("cwd", "")
    text = subject(tool, inp)

    for r in rules:
        if not isinstance(r, dict):
            continue
        # A rule naming "Bash" should also govern Cursor's "Shell".
        if r.get("tool") and r["tool"] != tool and not _same_tool(r["tool"], tool):
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
        # Denying broadly is merely annoying; allowing broadly is the whole attack.
        if action == "allow":
            if too_broad(pat):
                note(f"agentisland rules: refused a catch-all allow rule ({pat!r})")
                continue
            hit = next((n for n in NEVER_AUTO if n in text.lower()), None)
            if hit:
                note(f"agentisland rules: {hit!r} is never auto-approved; asking instead")
                continue
        note(f"agentisland rules: {action} by {pat!r}")
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "PermissionRequest",
            "permissionDecision": action,
            "permissionDecisionReason": f"AgentIsland rule: {pat}",
        }}))
        sys.exit(0)
    sys.exit(0)


if __name__ == "__main__":
    main()
