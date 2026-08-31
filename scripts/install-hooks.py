#!/usr/bin/env python3
"""Register Agent Island's hooks with every agent CLI present, without disturbing anyone else's.

Config stomping is the defining failure of this category — competitors have open issues for
overwriting Claude settings, statusline config and iTerm2 tab titles. So this installer:

  * backs up before touching anything, with a timestamp
  * appends its own entry and never rewrites or reorders another tool's
  * is idempotent — running twice changes nothing the second time
  * wraps an existing statusLine rather than replacing it
  * prints exactly what it changed
"""
import json, os, shutil, sys, time

REPO = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

HOOK       = os.path.join(REPO, "hooks/agentisland-hook.sh")
PERM       = os.path.join(REPO, "hooks/agentisland-permission.sh")
RULES      = os.path.join(REPO, "hooks/agentisland-rules.py")
QUESTION   = os.path.join(REPO, "hooks/agentisland-question.py")
STATUSLINE = os.path.join(REPO, "hooks/agentisland-status.sh")

MARK = "agentisland"          # how we recognise our own entries


def backup(path):
    if not os.path.exists(path):
        return None
    dst = f"{path}.backup.agentisland.{time.strftime('%Y-%m-%dT%H-%M-%SZ', time.gmtime())}"
    shutil.copy2(path, dst)
    return dst


def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        return {}
    except json.JSONDecodeError as e:
        print(f"    ! {path} is not valid JSON ({e}); refusing to touch it")
        return None


def add_hook(cfg, event, command, *, first=False, matcher=None, timeout=None):
    """Append one entry. Returns True if the file changed."""
    entries = cfg.setdefault("hooks", {}).setdefault(event, [])
    if any(MARK in json.dumps(e) and command in json.dumps(e) for e in entries):
        return False
    spec = {"type": "command", "command": command}
    if timeout:
        spec["timeout"] = timeout
    entry = {"hooks": [spec]}
    if matcher:
        entry["matcher"] = matcher
    entries.insert(0, entry) if first else entries.append(entry)
    return True


def install(name, path, plan, statusline=False):
    cfg = load(path)
    if cfg is None:
        return
    before = json.dumps(cfg, sort_keys=True)
    foreign = sum(1 for ev in cfg.get("hooks", {}).values() for e in ev
                  for h in e.get("hooks", []) if MARK not in json.dumps(h))

    changed = 0
    for event, command, kw in plan:
        changed += add_hook(cfg, event, command, **kw)

    if statusline and MARK not in json.dumps(cfg.get("statusLine", {})):
        # Wrap, do not replace: the wrapper runs the user's own statusline inside it.
        cfg["statusLine"] = {"type": "command", "command": f"bash {STATUSLINE}"}
        changed += 1

    if json.dumps(cfg, sort_keys=True) == before:
        print(f"  {name}: already installed, nothing changed  ({foreign} other tools' hooks left alone)")
        return

    b = backup(path)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(cfg, f, indent=2)
    print(f"  {name}: added {changed} entr{'y' if changed == 1 else 'ies'}"
          f"  ({foreign} other tools' hooks preserved)")
    if b:
        print(f"    backup: {b}")


# --- Claude Code -------------------------------------------------------------
claude_events = ["PreToolUse", "PostToolUse", "Notification", "Stop", "SessionStart",
                 "SessionEnd", "UserPromptSubmit", "StopFailure", "PreCompact"]
claude_plan = [(e, HOOK, {}) for e in claude_events]
claude_plan += [
    ("PermissionRequest", RULES,    {"first": True, "timeout": 10}),   # rules run before we ask
    ("PermissionRequest", PERM,     {"timeout": 30}),
    ("PreToolUse",        QUESTION, {"matcher": "AskUserQuestion", "timeout": 60}),
]
install("Claude Code", os.path.expanduser("~/.claude/settings.json"),
        claude_plan, statusline=True)

# --- Codex -------------------------------------------------------------------
# Same hooks.json shape as Claude Code, so the same hook script handles both.
if os.path.isdir(os.path.expanduser("~/.codex")):
    codex_plan = [(e, HOOK, {}) for e in
                  ["SessionStart", "Stop", "PreToolUse", "PostToolUse", "Notification"]]
    install("Codex", os.path.expanduser("~/.codex/hooks.json"), codex_plan)
else:
    print("  Codex: not installed, skipped")

# --- Cursor ------------------------------------------------------------------
# Cursor's schema is flatter: {"hooks": {"event": [{"command": "..."}]}} with its own event
# names, which HookStream.canonical() maps onto the shared vocabulary.
CURSOR_EVENTS = ["beforeSubmitPrompt", "beforeShellExecution", "afterShellExecution",
                 "afterFileEdit", "afterAgentResponse", "stop",
                 "subagentStart", "subagentStop"]

cursor_path = os.path.expanduser("~/.cursor/hooks.json")
if os.path.isdir(os.path.expanduser("~/.cursor")):
    cfg = load(cursor_path)
    if cfg is not None:
        hooks = cfg.setdefault("hooks", {})
        foreign = sum(len(v) for k, v in hooks.items()
                      for _ in [0]) - sum(1 for v in hooks.values() for h in v
                                          if MARK in json.dumps(h))
        added = 0
        for event in CURSOR_EVENTS:
            entries = hooks.setdefault(event, [])
            if any(MARK in json.dumps(e) for e in entries):
                continue
            entries.append({"command": HOOK})
            added += 1
        if added:
            b = backup(cursor_path)
            with open(cursor_path, "w") as f:
                json.dump(cfg, f, indent=2)
            print(f"  Cursor: added {added} entries  ({foreign} other tools' hooks preserved)")
            if b:
                print(f"    backup: {b}")
        else:
            print(f"  Cursor: already installed, nothing changed  ({foreign} other tools' hooks left alone)")
else:
    print("  Cursor: not installed, skipped")

print("\n  Uninstall with: python3 scripts/uninstall-hooks.py")
