#!/usr/bin/env python3
"""Remove every Agent Island hook, leaving every other tool's untouched.

"How do I completely and cleanly uninstall" is an open, unanswered question on a competitor's
tracker. This is the answer: it removes only entries this app added, restores a wrapped
statusLine to whatever it wrapped, and reports what it did.
"""
import json, os, pwd, shutil, sys, time

# This script is destructive and takes no arguments, so anything on the command line is a
# misunderstanding. `--help` used to uninstall everything and then report what it had done.
if len(sys.argv) > 1:
    print(__doc__)
    print("Usage: python3 scripts/uninstall-hooks.py      (takes no arguments)")
    print("       AGENTISLAND_KEEP_RUNTIME=1 python3 scripts/uninstall-hooks.py")
    print("            keeps the login item and the staged hooks")
    sys.exit(0 if sys.argv[1] in ("-h", "--help") else 2)

MARK = "agentisland"
# Matching the bare word would take a third-party hook whose path merely contains it. Our hooks
# are these six files, wherever the repo happens to sit — so an install at an old path is still
# recognised, and somebody else's tool is not.
SCRIPTS = ("agentisland-hook.sh", "agentisland-permission.sh", "agentisland-rules.py",
           "agentisland-question.py", "agentisland-input.py", "agentisland-status.sh",
           "agentisland-opencode.js")


def ours(obj):
    blob = json.dumps(obj)
    return any(name in blob for name in SCRIPTS)


def save(path, cfg):
    """Write-then-rename: a kill or full disk mid-write must never leave settings truncated."""
    tmp = path + ".agentisland.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2)
    os.replace(tmp, path)


def clean(name, path):
    if not os.path.exists(path):
        print(f"  {name}: no config, nothing to do")
        return
    try:
        with open(path, encoding="utf-8") as f:
            cfg = json.load(f)
    except json.JSONDecodeError:
        print(f"  {name}: config is not valid JSON, refusing to touch it")
        return

    removed, kept = 0, {}
    for event, entries in cfg.get("hooks", {}).items():
        survivors = []
        for entry in entries:
            if not isinstance(entry, dict) or "hooks" not in entry:
                survivors.append(entry)   # not ours, whatever shape it is — keep it
                continue
            hooks = [h for h in entry.get("hooks", []) if not ours(h)]
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
            cfg["statusLine"] = json.load(open(saved, encoding="utf-8"))
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
    save(path, cfg)
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
        with open(path, encoding="utf-8") as f:
            cfg = json.load(f)
    except json.JSONDecodeError:
        print("  Cursor: config is not valid JSON, refusing to touch it")
        return
    removed, kept = 0, {}
    for event, entries in cfg.get("hooks", {}).items():
        survivors = [e for e in entries if not ours(e)]
        removed += len(entries) - len(survivors)
        if survivors:
            kept[event] = survivors
    if not removed:
        print("  Cursor: nothing of ours found")
        return
    shutil.copy2(path, f"{path}.backup.agentisland-uninstall."
                       f"{time.strftime('%Y-%m-%dT%H-%M-%SZ', time.gmtime())}")
    cfg["hooks"] = kept
    save(path, cfg)
    print(f"  Cursor: removed {removed} hook(s); "
          f"{sum(len(v) for v in kept.values())} other hooks left intact")


clean_cursor(os.path.expanduser("~/.cursor/hooks.json"))
clean("Gemini CLI", os.path.expanduser("~/.gemini/settings.json"))

_oc = os.path.expanduser("~/.config/opencode/plugins/agentisland-opencode.js")
if os.path.exists(_oc):
    os.remove(_oc)
    print("  OpenCode: removed the plugin")
else:
    print("  OpenCode: nothing of ours found")

# The runtime files are shared, absolute paths — a sandboxed test uninstalling against its
# own HOME must not wipe the spool the user's running app is built on.
if os.environ.get("AGENTISLAND_KEEP_RUNTIME"):
    print("  kept runtime files (AGENTISLAND_KEEP_RUNTIME)")
else:
    # /tmp is not under HOME, so running this against a copied config — which is how you
    # test it — deleted the live app's state and stopped it. Skip the shared files when HOME
    # has been pointed somewhere else; the config cleanup above is still honoured.
    real_home = (os.environ.get("HOME") or "") == pwd.getpwuid(os.getuid()).pw_dir
    if not real_home:
        print("  left /tmp alone (HOME is not this user's, so this is a dry run)")
    else:
        for p in ["/tmp/agentisland-events.jsonl",
                  # rotation leaves one previous file beside the live one
                  "/tmp/agentisland-events.jsonl.1",
                  "/tmp/agentisland.alive", "/tmp/agentisland.log",
                  "/tmp/agentisland-status.json"]:
            if os.path.exists(p):
                os.remove(p)
        for d in ["/tmp/agentisland-decisions", "/tmp/agentisland-status"]:
            shutil.rmtree(d, ignore_errors=True)
        print("  removed runtime files from /tmp")
# install.sh registers a login item so a reboot brings the island back. Leaving it behind
# means an uninstalled app is relaunched at every login — the exact orphan this repo has
# already had to chase out of System Events once.
# The hooks themselves live outside the checkout now, so removing the entries is only half of
# leaving no trace.
STAGE = os.path.expanduser("~/Library/Application Support/AgentIsland")
if os.environ.get("AGENTISLAND_KEEP_RUNTIME"):
    print("  kept the staged hooks (AGENTISLAND_KEEP_RUNTIME)")
elif os.path.isdir(STAGE):
    shutil.rmtree(STAGE, ignore_errors=True)
    print("  removed the staged hook scripts")

# Both labels: the bundle id was renamed, and an install from before that left a second
# plist behind. Removing only the current one leaves a login item for an app that is gone.
AGENTS = [("io.github.tiwari1999.agentisland", "the login item"),
          ("sh.emergent.agentisland", "the login item from the old bundle id")]
if os.environ.get("AGENTISLAND_KEEP_RUNTIME"):
    print("  kept the login item (AGENTISLAND_KEEP_RUNTIME)")
else:
    for label, what in AGENTS:
        path = os.path.expanduser(f"~/Library/LaunchAgents/{label}.plist")
        if not os.path.exists(path):
            continue
        os.system(f"launchctl bootout gui/{os.getuid()}/{label} 2>/dev/null")
        os.remove(path)
        print(f"  removed {what}, so a reboot no longer relaunches it")

# The terminal-focus extension install-hooks.py put into VS Code and Cursor.
for name, ext_dir, cli in (
        ("VS Code", "~/.vscode/extensions",
         "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"),
        ("Cursor", "~/.cursor/extensions", "/Applications/Cursor.app/Contents/Resources/app/bin/cursor")):
    try:
        listed = open(os.path.join(os.path.expanduser(ext_dir), "extensions.json"), encoding="utf-8").read()
    except OSError:
        continue
    if '"agentisland.ide-focus"' not in listed or not os.access(cli, os.X_OK):
        continue
    import subprocess
    r = subprocess.run([cli, "--uninstall-extension", "agentisland.ide-focus"],
                       capture_output=True, text=True, timeout=120)
    print(f"  {name}: {'removed the terminal-focus extension' if r.returncode == 0 else 'could not remove the extension: ' + r.stderr.strip()[:160]}")

print("\n  Left in place (yours, not ours): ~/.agentisland/rules.json")
print("  Remove the app with: rm -rf ~/Applications/AgentIsland.app")
