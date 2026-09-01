#!/usr/bin/env python3
"""Does clicking an agent actually land on that agent's tab?

The claim this app is built on is that its jump is precise where the category's is not, and the
case that decides it is the one every monorepo user lives in: several agents in Warp tabs that all
share one working directory. A resolver keyed on the directory cannot tell those tabs apart.

Nothing here trusts the app's own account of what it did. Each tab is given an identity, the jump
is driven through the binary's real row-click path, and the tab that answers afterwards is asked
who it is. That answer is the measurement.

  python3 tests/routing.py                 # 8 tabs, 20 trials, against Agent Island
  python3 tests/routing.py --tabs 3 --trials 6
"""
import argparse, atexit, os, random, subprocess, sys, time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.path.join(REPO, ".build/release/AgentIsland")
WORK = "/tmp/ai-routing"
TABS_FILE = f"{WORK}/tabs.txt"
LANDED = f"{WORK}/landed"


def osa(script):
    return subprocess.run(["osascript", "-e", script], capture_output=True, text=True)


def warp_is_frontmost():
    r = osa('tell application "System Events" to return name of first process whose frontmost is true')
    return r.stdout.strip() == "Warp"


def type_into_warp(text, enter=True):
    """Type into the focused Warp pane — but only once Warp is genuinely frontmost.

    Typing blind is how an earlier version of this harness sent its setup line into the user's
    own Claude Code session: when Warp was not frontmost, the new-tab shortcut opened nothing and
    the text went wherever focus happened to be. Never type without checking.
    """
    if not warp_is_frontmost():
        osa('tell application "Warp" to activate')
        time.sleep(0.8)
        if not warp_is_frontmost():
            raise RuntimeError("Warp is not frontmost — refusing to type into another app")
    esc = text.replace("\\", "\\\\").replace('"', '\\"')
    script = f'tell application "System Events" to tell process "Warp" to keystroke "{esc}"'
    osa(script)
    if enter:
        osa('tell application "System Events" to tell process "Warp" to key code 36')


def focus_warp():
    osa('tell application "Warp" to activate')
    time.sleep(0.45)


def ask_focused_tab(timeout=5.0, tries=2):
    """Ask the focused pane which tab it is. The pane answers for itself; we never infer.

    Retried once: a keystroke sent while Warp is still animating a tab change is dropped
    silently, which would otherwise be recorded as a routing miss.
    """
    for attempt in range(tries):
        try:
            os.remove(LANDED)
        except FileNotFoundError:
            pass
        type_into_warp(f'echo ${{AI_TABID:-none}} > {LANDED}')
        deadline = time.time() + timeout
        while time.time() < deadline:
            if os.path.exists(LANDED):
                v = open(LANDED).read().strip()
                if v:
                    return v
            time.sleep(0.1)
        time.sleep(0.6)
    return "none"


def tab_registered(i):
    for line in (open(TABS_FILE).read().splitlines() if os.path.exists(TABS_FILE) else []):
        p = line.split()
        if len(p) >= 3 and p[0] == str(i) and p[2].startswith("warp://"):
            return True
    return False


def open_tabs(n, workdir):
    """One Warp tab per agent, every one of them in the same directory.

    Each tab has to confirm itself before we move on. A tab that never reports cannot be focused
    by handle later, so it could neither be measured nor closed — it is shut immediately instead
    of being left behind in the user's window.
    """
    focus_warp()
    opened = 0
    for i in range(1, n + 1):
        osa('tell application "System Events" to tell process "Warp" to keystroke "t" using command down')
        time.sleep(2.2)
        # The stand-in agent must be a CHILD of the shell, as every real agent is: Warp exports
        # WARP_FOCUS_URL from the rc file, so it is absent from the shell's own starting
        # environment and present in everything the shell launches. Recording the shell's pid
        # instead measures a process that legitimately has no handle.
        agent = os.path.join(REPO, "tests/_routing_agent.sh")
        type_into_warp(f'cd {workdir}; export AI_TABID={i}; bash {agent} {i} {TABS_FILE} &')

        deadline = time.time() + 8
        while time.time() < deadline and not tab_registered(i):
            time.sleep(0.25)
        if tab_registered(i):
            opened += 1
        else:
            # A tab that never reported means the keystroke went somewhere unknown. Stop rather
            # than type again into a pane we cannot identify.
            raise RuntimeError(
                f"tab {i} never reported a handle — aborting before typing anywhere else")
    return opened


def read_tabs():
    rows = {}
    if not os.path.exists(TABS_FILE):
        return rows
    for line in open(TABS_FILE):
        parts = line.split()
        if len(parts) >= 3 and parts[2].startswith("warp://"):
            rows[parts[0]] = {"pid": int(parts[1]), "url": parts[2]}
    return rows


def close_tabs(tabs):
    """Only ever closes a tab that identifies itself as ours."""
    for info in tabs.values():
        subprocess.run(["kill", str(info["pid"])], capture_output=True)
    for tabid, info in tabs.items():
        subprocess.run(["open", info["url"]], capture_output=True)
        time.sleep(0.9)
        if ask_focused_tab(timeout=3.0) == tabid:
            type_into_warp("exit")
            time.sleep(0.7)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tabs", type=int, default=8)
    ap.add_argument("--trials", type=int, default=20)
    ap.add_argument("--keep", action="store_true", help="leave the tabs open for inspection")
    args = ap.parse_args()

    if not os.path.exists(BIN):
        sys.exit("build first: swift build -c release")

    # Keystrokes go nowhere while the display is asleep, and they fail silently when they do.
    # -d as well as -u: a sleeping display swallows every keystroke silently, which reads as a
    # routing miss rather than as the measurement failure it is.
    caf = subprocess.Popen(["caffeinate", "-d", "-u", "-t", "1800"])
    atexit.register(caf.terminate)
    time.sleep(2.5)

    os.makedirs(WORK, exist_ok=True)
    open(TABS_FILE, "w").close()
    workdir = REPO  # a real repository, which is the whole point: every tab shares it

    print(f"  bed: {args.tabs} Warp tabs, all in {workdir}")
    try:
        open_tabs(args.tabs, workdir)
    except RuntimeError as e:
        print(f"  {e}")
        close_tabs(read_tabs())
        return 2
    time.sleep(1.0)


    tabs = read_tabs()
    print(f"  tabs that reported a Warp session handle: {len(tabs)}/{args.tabs}")
    if len(tabs) < 2:
        sys.exit("  need at least two tabs sharing a directory for this to mean anything")

    # Every tab shares one directory, so a directory-keyed resolver has nothing to choose between.
    dirs = {workdir}
    print(f"  distinct working directories across those tabs: {len(dirs)}  "
          f"(a cwd-keyed resolver has a 1-in-{len(tabs)} chance)")

    ids = sorted(tabs)
    hits = misses = unresolved = 0
    aimed_right = 0
    for n in range(args.trials):
        want = ids[n % len(ids)] if n < len(ids) else random.choice(ids)
        pid = tabs[want]["pid"]

        r = subprocess.run([BIN, "--jump-pid", str(pid)], capture_output=True, text=True)
        if r.returncode != 0:
            unresolved += 1
            print(f"    trial {n+1:>2}: asked for tab {want:>2}  unresolved  {r.stdout.strip()}")
            continue

        # Two independent measurements: where it aimed, and where it actually landed.
        target = ""
        for tok in r.stdout.split():
            if tok.startswith("target="):
                target = tok.split("=", 1)[1]
        if target == tabs[want]["url"]:
            aimed_right += 1

        time.sleep(2.2)
        got = ask_focused_tab()
        if got == want:
            hits += 1
        else:
            misses += 1
        print(f"    trial {n+1:>2}: asked for tab {want:>2}  landed on {got:>4}  "
              f"{'ok' if got == want else 'WRONG'}")

    total = hits + misses + unresolved
    rate = 100.0 * hits / total if total else 0.0
    print(f"\n  aimed at the right tab's handle: {aimed_right}/{total}")
    print(f"  landed on the right tab:         {hits}/{total}  ({rate:.0f}%)")
    if unresolved:
        print(f"  unresolved (no handle, degraded rather than guessing): {unresolved}")

    if not args.keep:
        print("  closing the tabs this test opened")
        close_tabs(tabs)

    # The PRD's bar: a wedge exists only if this app is near-perfect here.
    print("\n  ROUTING PASS" if rate >= 95 else f"\n  ROUTING FAIL ({rate:.0f}% < 95%)")
    return 0 if rate >= 95 else 1


if __name__ == "__main__":
    sys.exit(main())
