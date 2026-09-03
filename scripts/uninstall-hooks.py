#!/usr/bin/env python3
"""Remove every Agent Island hook, leaving every other tool's untouched.

"How do I completely and cleanly uninstall" is an open, unanswered question on a competitor's
tracker. This is the answer: it removes only entries this app added, restores a wrapped
statusLine to whatever it wrapped, and reports what it did.
"""
import json, os, shutil, time

MARK = "agentisland"


def clean(name, path):
    if not os.path.exists(path):
        print(f"  {name}: no config, nothing to do")
        return
    try:
        with open(path) as f:
            cfg = json.load(f)
    except json.JSONDecodeError:
        print(f"  {name}: config is not valid JSON, refusing to touch it")
        return

    removed, kept = 0, {}
    for event, entries in cfg.get("hooks", {}).items():
        survivors = []
        for entry in entries:
            hooks = [h for h in entry.get("hooks", []) if MARK not in json.dumps(h)]
            removed += len(entry.get("hooks", [])) - len(hooks)
            if hooks:
                survivors.append({**entry, "hooks": hooks})
        if survivors:
            kept[event] = survivors

    sl = 0
    if MARK in json.dumps(cfg.get("statusLine", {})):
        # The wrapper ran the user's own statusline; hand it back rather than deleting the key.
        saved = os.path.expanduser("~/.agentisland/prev-statusline.json")
        user = os.path.expanduser("~/.claude/statusline-command.sh")
        if os.path.exists(saved):
            cfg["statusLine"] = json.load(open(saved))
            for f in (saved, saved[: -len(".json")]):
                os.remove(f)
        elif os.path.exists(user):
            cfg["statusLine"] = {"type": "command", "command": f"bash {user}"}
        else:
            cfg.pop("statusLine", None)
        sl = 1

    if not removed and not sl:
        print(f"  {name}: nothing of ours found")
        return

    shutil.copy2(path, f"{path}.backup.agentisland-uninstall."
                       f"{time.strftime('%Y-%m-%dT%H-%M-%SZ', time.gmtime())}")
    cfg["hooks"] = kept
    with open(path, "w") as f:
        json.dump(cfg, f, indent=2)
    print(f"  {name}: removed {removed} hook(s)"
          + (", restored statusLine" if sl else "")
          + f"; {sum(len(e.get('hooks', [])) for ev in kept.values() for e in ev)} other hooks left intact")


clean("Claude Code", os.path.expanduser("~/.claude/settings.json"))
clean("Codex", os.path.expanduser("~/.codex/hooks.json"))


def clean_cursor(path):
    """Cursor's schema is flat — {"hooks": {"event": [{"command": ...}]}} — so it needs its own
    pass rather than the nested walk above."""
    if not os.path.exists(path):
        print("  Cursor: no config, nothing to do")
        return
    try:
        with open(path) as f:
            cfg = json.load(f)
    except json.JSONDecodeError:
        print("  Cursor: config is not valid JSON, refusing to touch it")
        return
    removed, kept = 0, {}
    for event, entries in cfg.get("hooks", {}).items():
        survivors = [e for e in entries if MARK not in json.dumps(e)]
        removed += len(entries) - len(survivors)
        if survivors:
            kept[event] = survivors
    if not removed:
        print("  Cursor: nothing of ours found")
        return
    shutil.copy2(path, f"{path}.backup.agentisland-uninstall."
                       f"{time.strftime('%Y-%m-%dT%H-%M-%SZ', time.gmtime())}")
    cfg["hooks"] = kept
    with open(path, "w") as f:
        json.dump(cfg, f, indent=2)
    print(f"  Cursor: removed {removed} hook(s); "
          f"{sum(len(v) for v in kept.values())} other hooks left intact")


clean_cursor(os.path.expanduser("~/.cursor/hooks.json"))

# The runtime files are shared, absolute paths — a sandboxed test uninstalling against its
# own HOME must not wipe the spool the user's running app is built on.
if os.environ.get("AGENTISLAND_KEEP_RUNTIME"):
    print("  kept runtime files (AGENTISLAND_KEEP_RUNTIME)")
else:
    for p in ["/tmp/agentisland-events.jsonl", "/tmp/agentisland.alive", "/tmp/agentisland.log",
              "/tmp/agentisland-status.json"]:
        if os.path.exists(p):
            os.remove(p)
    for d in ["/tmp/agentisland-decisions", "/tmp/agentisland-status"]:
        shutil.rmtree(d, ignore_errors=True)
    print("  removed runtime files from /tmp")
print("\n  Left in place (yours, not ours): ~/.agentisland/rules.json")
print("  Remove the app with: rm -rf ~/Applications/AgentIsland.app")
