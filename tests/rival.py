#!/usr/bin/env python3
"""Head-to-head: Agent Island's jump vs Open Island's, on the bed that decides it.

Four REAL Claude Code sessions in four Warp tabs, every one in the same repository directory.
Each session is asked to reply with its own tab marker, so the marker is visible in the pane and
in each app's row — the pane itself is the oracle for where a jump landed.

Open Island (v1.1.8) resolves Warp tabs by reading warp.sqlite and driving a keystroke loop
(its own binary strings: "Warp tab advance", "Activated Warp but could not confirm precision
focus"). warp.sqlite keys panes by cwd, and every tab here shares one cwd. Agent Island reads
WARP_FOCUS_URL from the agent process's own environment, which is per-session by construction.

This harness only drives the clicks and captures screenshots; a human (or the calling agent)
reads each screenshot to judge the landing, because Warp exposes no AX surface to ask.

  python3 tests/rival.py setup        # open tabs, start sessions, label them
  python3 tests/rival.py truth        # print session -> tab ground truth
  python3 tests/rival.py jump-ai N    # Agent Island's jump to tab N's session
  python3 tests/rival.py jump-oi N    # click Open Island's row for tab N
  python3 tests/rival.py shot OUT     # screenshot the Warp pane area
  python3 tests/rival.py teardown     # end sessions, close tabs, remove nothing else
"""
import json, os, re, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import routing  # reuses the guarded typing, tab opening, caffeinate discipline

REPO = routing.REPO
BIN = routing.BIN
WORK = "/tmp/ai-oi"
STATE = f"{WORK}/bed.json"
N_TABS = 4


def osa(script):
    return subprocess.run(["osascript", "-e", script], capture_output=True, text=True)


def claude_agents():
    out = subprocess.run(["/opt/homebrew/bin/claude", "agents", "--json", "--all"],
                         capture_output=True, text=True).stdout
    try:
        return json.loads(out)
    except Exception:
        return []


def env_of(pid):
    out = subprocess.run(["ps", "eww", "-o", "command=", "-p", str(pid)],
                         capture_output=True, text=True).stdout
    env = {}
    for tok in out.split():
        if "=" in tok:
            k, _, v = tok.partition("=")
            env[k] = v
    return env


def setup():
    os.makedirs(WORK, exist_ok=True)
    subprocess.Popen(["caffeinate", "-d", "-u", "-t", "2400"])
    time.sleep(2)
    before = {a.get("pid") for a in claude_agents() if a.get("pid")}

    routing.focus_warp()
    for i in range(1, N_TABS + 1):
        routing.osa('tell application "System Events" to tell process "Warp" to keystroke "t" using command down')
        time.sleep(2.2)
        # AI_TABID rides into claude's environment, which is the ground-truth binding:
        # the session whose process carries AI_TABID=N lives in tab N. No inference.
        routing.type_into_warp(f"cd {REPO}; export AI_TABID={i}; claude")
        time.sleep(1.0)

    print("  waiting for the sessions to come up...")
    time.sleep(18)

    # Label each pane so screenshots can identify it. One tiny prompt per session.
    bed = {}
    for a in claude_agents():
        pid = a.get("pid")
        if not pid or pid in before:
            continue
        env = env_of(pid)
        tab = env.get("AI_TABID")
        url = env.get("WARP_FOCUS_URL")
        if tab and url:
            bed[tab] = {"pid": pid, "url": url, "session": a.get("sessionId") or a.get("session_id")}
    json.dump(bed, open(STATE, "w"), indent=1)
    print(f"  sessions bound to tabs: {sorted(bed)}")

    for tab, info in sorted(bed.items()):
        subprocess.run(["open", info["url"]])
        time.sleep(1.8)
        routing.type_into_warp(
            f"Reply with exactly OI-TAB-{tab} in a code block and nothing else.")
        time.sleep(1.0)
    print("  markers sent; give the replies ~20s to render")


def truth():
    bed = json.load(open(STATE))
    for tab, info in sorted(bed.items()):
        print(f"  tab {tab}: pid {info['pid']}  {info['url']}  session {str(info.get('session'))[:8]}")


def jump_ai(tab):
    bed = json.load(open(STATE))
    info = bed[str(tab)]
    r = subprocess.run([BIN, "--jump-pid", str(info["pid"])], capture_output=True, text=True)
    print(f"  {r.stdout.strip()}")
    return r.returncode


def oi_rows():
    """Row texts and positions from Open Island's expanded panel."""
    script = '''
    tell application "System Events" to tell process "OpenIslandApp"
      set sa to first UI element of first UI element of front window whose role is "AXScrollArea"
      set out to {}
      repeat with t in static texts of sa
        set p to position of t
        set end of out to (item 1 of p as text) & "," & (item 2 of p as text) & "|" & (value of t as text)
      end repeat
      set AppleScript's text item delimiters to linefeed
      return out as text
    end tell'''
    r = osa(script)
    rows = []
    for line in r.stdout.splitlines():
        m = re.match(r"([-\d]+),([-\d]+)\|(.*)", line)
        if m:
            rows.append((int(m.group(1)), int(m.group(2)), m.group(3)))
    return rows


def expand_oi():
    subprocess.run(["/tmp/crop/movecur", "notch"], capture_output=True)
    time.sleep(1.4)
    subprocess.run(["/tmp/crop/movecur", "panel"], capture_output=True)
    time.sleep(1.2)


def jump_oi(tab):
    expand_oi()
    marker = f"OI-TAB-{tab}"
    rows = oi_rows()
    hit = next(((x, y, t) for x, y, t in rows if marker in t), None)
    if not hit:
        print(f"  no Open Island row mentions {marker}")
        print("  rows seen:")
        for _, _, t in rows[:10]:
            print(f"    {t[:90]}")
        return 1
    x, y, _ = hit
    # Click the row itself: the per-row AXButton is only the expand chevron.
    subprocess.run(["/tmp/crop/movecur", "xy", str(x + 30), str(y + 4)], capture_output=True)
    time.sleep(0.4)
    osa(f'tell application "System Events" to click at {{{x + 30}, {y + 4}}}')
    print(f"  clicked Open Island row for {marker} at ({x + 30},{y + 4})")
    return 0


def shot(out):
    time.sleep(2.2)
    subprocess.run(["/usr/sbin/screencapture", "-x", out])
    print(f"  wrote {out}")


def teardown():
    bed = json.load(open(STATE)) if os.path.exists(STATE) else {}
    for tab, info in sorted(bed.items()):
        subprocess.run(["open", info["url"]])
        time.sleep(1.6)
        # /exit ends the claude session cleanly; then the shell gets its exit.
        routing.type_into_warp("/exit")
        time.sleep(2.5)
        routing.type_into_warp("exit")
        time.sleep(1.0)
    print("  bed torn down")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "setup":
        setup()
    elif cmd == "truth":
        truth()
    elif cmd == "jump-ai":
        sys.exit(jump_ai(sys.argv[2]))
    elif cmd == "jump-oi":
        sys.exit(jump_oi(sys.argv[2]))
    elif cmd == "shot":
        shot(sys.argv[2])
    elif cmd == "teardown":
        teardown()
    else:
        print(__doc__)
