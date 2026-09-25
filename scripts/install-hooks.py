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
import json
import re, os, shlex, shutil, sys, time

REPO = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

SCRIPTS = ("agentisland-hook.sh", "agentisland-permission.sh", "agentisland-rules.py",
           "agentisland-question.py", "agentisland-input.py", "agentisland-status.sh")

# Where the hooks to install are read FROM: a git checkout when run from one, the app bundle
# when the app runs its own copy. Run from inside the bundle with no argument, REPO resolved to
# `AgentIsland.app/Contents`, whose `hooks/` does not exist — so a download-only user registered
# fourteen entries pointing at nothing, was told hooks were installed, and had none.
def _source():
    here = os.path.dirname(os.path.abspath(__file__))
    for base in (REPO, here, os.path.dirname(here)):
        d = os.path.join(base, "hooks")
        if all(os.path.exists(os.path.join(d, n)) for n in SCRIPTS):
            return d
    return None


SOURCE = _source()

# ...and where they are installed TO. Registering the checkout meant deleting the clone, or
# moving the app, silently disarmed every hook while the settings still looked correct. This
# path belongs to the user and outlives both.
STAGE = os.path.expanduser("~/Library/Application Support/AgentIsland/hooks")


def stage_hooks():
    """Copy the hooks somewhere stable and return True once they are all runnable."""
    if not SOURCE:
        print("  !! cannot find the hook scripts to install — nothing was changed")
        return False
    os.makedirs(STAGE, exist_ok=True)
    for name in SCRIPTS:
        dst = os.path.join(STAGE, name)
        shutil.copy2(os.path.join(SOURCE, name), dst)
        os.chmod(dst, 0o755)
    return True


# Every agent CLI runs a hook command through a shell, so a path with a space in it registered a
# command that split into two words and never ran. shlex.quote is a no-op for ordinary paths.
def _cmd(name):
    return shlex.quote(os.path.join(STAGE, name))


HOOK       = _cmd("agentisland-hook.sh")
PERM       = _cmd("agentisland-permission.sh")
RULES      = _cmd("agentisland-rules.py")
QUESTION   = _cmd("agentisland-question.py")
INPUT      = _cmd("agentisland-input.py")
STATUSLINE = os.path.join(STAGE, "agentisland-status.sh")   # quoted where it is used

MARK = "agentisland"          # how we recognise our own entries
# The bare word is too broad to delete on: a third-party hook living under a path that merely
# contains it is not ours. Ours are these six files, wherever the repo sits — so a copy at an
# old path is still recognised as a leftover, and somebody else's tool is left alone.
SCRIPTS = ("agentisland-hook.sh", "agentisland-permission.sh", "agentisland-rules.py",
           "agentisland-question.py", "agentisland-input.py", "agentisland-status.sh")


def ours(obj):
    blob = json.dumps(obj)
    return any(name in blob for name in SCRIPTS)
STATE = os.path.expanduser("~/.agentisland")


def backup(path):
    if not os.path.exists(path):
        return None
    dst = f"{path}.backup.agentisland.{time.strftime('%Y-%m-%dT%H-%M-%SZ', time.gmtime())}"
    shutil.copy2(path, dst)
    return dst


def save(path, cfg):
    """Write-then-rename: a kill or full disk mid-write must never leave settings truncated."""
    tmp = path + ".agentisland.tmp"
    with open(tmp, "w") as f:
        json.dump(cfg, f, indent=2)
    os.replace(tmp, path)


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
    """Install one entry, replacing our own stale copies. Returns True if the file changed."""
    entries = cfg.setdefault("hooks", {}).setdefault(event, [])
    # Drop our own entries for this script that point somewhere else. Matching on the exact
    # command string meant a moved or re-cloned repo registered a second copy beside the first,
    # so every hook fired twice and dead paths accumulated.
    # shlex.split, not split: a quoted path (one containing a space) would otherwise
    # keep its closing quote and match nothing, resurrecting the duplicate-entry bug.
    script = os.path.basename(shlex.split(command)[-1])
    kept = [e for e in entries
            if not (MARK in json.dumps(e) and script in json.dumps(e)
                    and command not in json.dumps(e))]
    replaced = len(entries) - len(kept)
    if replaced:
        entries[:] = kept
    spec = {"type": "command", "command": command}
    if timeout:
        spec["timeout"] = timeout
    # Reconcile an entry we already own rather than leaving it alone. A changed timeout used
    # to be ignored for the life of the install, so upgrades kept the old deadline.
    for e in entries:
        for i, h in enumerate(e.get("hooks", [])):
            if MARK in json.dumps(h) and command in json.dumps(h):
                drift = h != spec or (e.get("matcher") or None) != (matcher or None)
                e["hooks"][i] = spec
                if matcher:
                    e["matcher"] = matcher
                return replaced > 0 or drift
    entry = {"hooks": [spec]}
    if matcher:
        entry["matcher"] = matcher
    entries.insert(0, entry) if first else entries.append(entry)
    return True


def install(name, path, plan, statusline=False):
    probe = load(path)
    if probe is not None and not isinstance(probe.get("hooks", {}), dict):
        print(f"  {name}: 'hooks' is not an object — leaving this file alone")
        return
    cfg = load(path)
    if cfg is None:
        return
    before = json.dumps(cfg, sort_keys=True)
    foreign = sum(1 for ev in cfg.get("hooks", {}).values() for e in ev
                  for h in e.get("hooks", []) if MARK not in json.dumps(h))

    changed = 0
    for event, command, kw in plan:
        changed += add_hook(cfg, event, command, **kw)

    # Sweep our entries that point at a different copy of this repo, on any event -- including
    # events an older version of this installer used and this one no longer does. Ours always
    # live under REPO; anything else marked as ours is a leftover that would still fire.
    for event, entries in list(cfg.get("hooks", {}).items()):
        kept = [e for e in entries
                if not (ours(e) and STAGE not in json.dumps(e))]
        if len(kept) != len(entries):
            changed += len(entries) - len(kept)
            entries[:] = kept
        if not entries:
            del cfg["hooks"][event]

    want_status = f"bash {shlex.quote(STATUSLINE)}"
    have_status = json.dumps(cfg.get("statusLine", {}))
    if statusline and MARK in have_status and want_status not in have_status:
        cfg["statusLine"] = {"type": "command", "command": want_status}   # ours, but stale path
        changed += 1
    elif statusline and MARK not in have_status:
        # Wrap, do not replace: remember whatever was there so the wrapper can run it and the
        # uninstaller can hand it back exactly. Only the conventional path survived before this.
        if isinstance(cfg.get("statusLine"), str) and cfg["statusLine"].strip():
            cfg["statusLine"] = {"type": "command", "command": cfg["statusLine"]}
        if isinstance(cfg.get("statusLine"), dict) and cfg["statusLine"].get("command"):
            os.makedirs(STATE, exist_ok=True)
            with open(os.path.join(STATE, "prev-statusline.json"), "w") as f:
                json.dump(cfg["statusLine"], f)
            with open(os.path.join(STATE, "prev-statusline"), "w") as f:
                f.write(cfg["statusLine"]["command"])   # plain text: the wrapper runs it as-is
        cfg["statusLine"] = {"type": "command", "command": f"bash {shlex.quote(STATUSLINE)}"}
        changed += 1

    if json.dumps(cfg, sort_keys=True) == before:
        print(f"  {name}: already installed, nothing changed  ({foreign} other tools' hooks left alone)")
        return

    b = backup(path)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    save(path, cfg)
    print(f"  {name}: added {changed} entr{'y' if changed == 1 else 'ies'}"
          f"  ({foreign} other tools' hooks preserved)")
    if b:
        print(f"    backup: {b}")


# Nothing may be registered before the scripts are in place, or the settings would again
# describe hooks that are not there.
if not stage_hooks():
    sys.exit(1)
print(f"  hooks staged in {STAGE}")

# --- Claude Code -------------------------------------------------------------
claude_events = ["PreToolUse", "PostToolUse", "Notification", "Stop", "SessionStart",
                 "SessionEnd", "UserPromptSubmit", "StopFailure", "PreCompact"]
claude_plan = [(e, HOOK, {}) for e in claude_events]
claude_plan += [
    ("PermissionRequest", RULES,    {"first": True, "timeout": 10}),   # rules run before we ask
    ("PermissionRequest", PERM,     {"timeout": 30}),
    ("PreToolUse",        QUESTION, {"matcher": "AskUserQuestion", "timeout": 310}),
    # Answers a reply typed in the notch for a terminal that takes no input of its own.
    ("Stop",              INPUT,    {"timeout": 5}),
]
# Gated like Codex and Cursor below. Installing unconditionally created a settings file — and
# a statusLine — for a tool a Codex-only or Cursor-only user has never had. Re-running this
# after installing Claude Code picks it up; install.sh runs it every time.
if os.path.isdir(os.path.expanduser("~/.claude")):
    install("Claude Code", os.path.expanduser("~/.claude/settings.json"),
            claude_plan, statusline=True)
else:
    print("  Claude Code: not installed, skipped")

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
            # Claude and Codex replace an entry whose path has moved; Cursor skipped the event
            # entirely if ANY of ours was there, so a repo that moved left Cursor pointing at a
            # path that no longer exists — silently, for ever.
            stale = [e for e in entries if ours(e) and STAGE not in json.dumps(e)]
            for e in stale:
                entries.remove(e)
            if any(MARK in json.dumps(e) for e in entries):
                continue
            entries.append({"command": HOOK})
            added += 1
        if added:
            b = backup(cursor_path)
            save(cursor_path, cfg)
            print(f"  Cursor: added {added} entries  ({foreign} other tools' hooks preserved)")
            if b:
                print(f"    backup: {b}")
        else:
            print(f"  Cursor: already installed, nothing changed  ({foreign} other tools' hooks left alone)")
else:
    print("  Cursor: not installed, skipped")

print("\n  Uninstall with: python3 scripts/uninstall-hooks.py")

# The harness kills a hook at the timeout in settings.json whatever the hook believes. When
# that number sits below the hook's own window the failure is silent and late: the reader
# answers in the notch, the hook is already dead, and the answer is written to a file nobody
# reads. Say so here rather than at answer time.
def check_deadline():
    try:
        src = open(os.path.join(REPO, "hooks/agentisland-question.py")).read()
        window = float(re.search(r'AGENTISLAND_Q_TIMEOUT", "([0-9.]+)"', src).group(1))
    except Exception:
        return
    for path in (os.path.expanduser("~/.claude/settings.json"),):
        cfg = load(path)
        if not isinstance(cfg, dict) or not isinstance(cfg.get("hooks"), dict):
            continue
        groups = cfg["hooks"].get("PreToolUse")
        if not isinstance(groups, list):
            continue
        for group in groups:
            if not isinstance(group, dict):
                continue
            for h in group.get("hooks", []) if isinstance(group.get("hooks"), list) else []:
                if not isinstance(h, dict):
                    continue
                if "agentisland-question" not in json.dumps(h):
                    continue
                t = h.get("timeout")
                if t is None or float(t) <= window:
                    print(f"\n  ! {path}")
                    print(f"    the question hook waits {window:.0f}s but Claude Code will kill it "
                          f"at {t if t is not None else 600}s.")
                    print("    Answers given after that are written and never read. Re-run this "
                          "installer, or raise the timeout by hand.")


check_deadline()
