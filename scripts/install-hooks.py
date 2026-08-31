#!/usr/bin/env python3
"""Register AgentIsland's hooks in ~/.claude/settings.json without disturbing anyone else's."""
import json, os, sys

repo = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
settings = os.path.expanduser("~/.claude/settings.json")
cfg = json.load(open(settings)) if os.path.exists(settings) else {}

hook = os.path.join(repo, "hooks/agentisland-hook.sh")
perm = os.path.join(repo, "hooks/agentisland-permission.sh")
rules = os.path.join(repo, "hooks/agentisland-rules.py")
quest = os.path.join(repo, "hooks/agentisland-question.py")
status = os.path.join(repo, "hooks/agentisland-status.sh")

hooks = cfg.setdefault("hooks", {})
def add(event, command, first=False, matcher=None, timeout=None):
    entries = hooks.setdefault(event, [])
    if any(command in json.dumps(e) for e in entries):
        return
    spec = {"type": "command", "command": command}
    if timeout: spec["timeout"] = timeout
    entry = {"hooks": [spec]}
    if matcher: entry["matcher"] = matcher
    entries.insert(0, entry) if first else entries.append(entry)

for ev in ("PreToolUse", "PostToolUse", "Notification", "Stop", "SessionStart",
           "SessionEnd", "UserPromptSubmit", "StopFailure", "PreCompact"):
    add(ev, hook)
add("PermissionRequest", rules, first=True, timeout=10)   # rules run before we ask
add("PermissionRequest", perm, timeout=30)
add("PreToolUse", quest, matcher="AskUserQuestion", timeout=60)

# Wrap any existing statusLine rather than replacing it.
if "agentisland-status" not in json.dumps(cfg.get("statusLine", {})):
    cfg["statusLine"] = {"type": "command", "command": f"bash {status}"}

os.makedirs(os.path.dirname(settings), exist_ok=True)
json.dump(cfg, open(settings, "w"), indent=2)
print(f"    hooks registered for {len(hooks)} events")
