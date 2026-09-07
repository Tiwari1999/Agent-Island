#!/usr/bin/env python3
"""Per-terminal jump E2E: Warp, iTerm2, Terminal.app.

Opens two real sessions in each installed terminal, then runs the exact focus logic the app's
HostTerminal.jump() uses and checks it lands on the intended session rather than the other one —
the whole point of the "precise jump". A terminal that is not installed is skipped, not failed.

This spawns GUI windows, so it is kept out of the default self-test and run on demand:

    python3 tests/terminals-e2e.py

Warp is verified by resolution (its focus URL is opened by the OS and has no scripting read-back);
iTerm2 and Terminal are verified by a full round-trip: create → focus the other → jump → confirm.
"""
import subprocess, sys, time

fails, ran = [], []


def osa(script):
    r = subprocess.run(["osascript", "-e", script] if "\n" not in script
                       else ["osascript"], input=None if "\n" not in script else script,
                       capture_output=True, text=True)
    return r.stdout.strip(), r.stderr.strip()


def osa_script(script):
    r = subprocess.run(["osascript"], input=script, capture_output=True, text=True)
    return r.stdout.strip(), r.stderr.strip()


def installed(app):
    import os
    return any(os.path.isdir(f"{p}/{app}.app")
               for p in ("/Applications", "/System/Applications/Utilities",
                         os.path.expanduser("~/Applications")))


def check(name, ok, detail=""):
    print(f"  {'PASS' if ok else 'FAIL'}  {name}" + (f"  — {detail}" if detail else ""))
    if not ok:
        fails.append(name)


# ---- iTerm2: match on the UUID after the "wNtNpN:" prefix, exactly as HostTerminal does ----
def test_iterm():
    if not installed("iTerm"):
        print("iTerm2: not installed, skipped"); return
    ran.append("iTerm2")
    out, err = osa_script('''
    tell application "iTerm"
      activate
      set w1 to (create window with default profile)
      set s1 to id of current session of w1
      set w2 to (create window with default profile)
      set s2 to id of current session of w2
      select w1
      return s1 & "|" & s2
    end tell''')
    if "|" not in out:
        check("iTerm2 opened two sessions", False, err or out); return
    s1, s2 = out.split("|", 1)
    # HostTerminal carries ITERM_SESSION_ID ("wNtNpN:UUID"); the jump matches on the UUID.
    handle = f"w9t9p9:{s2}"
    uuid = handle.split(":")[-1]
    osa_script(f'''
    tell application "iTerm"
      activate
      repeat with w in windows
        repeat with t in tabs of w
          repeat with s in sessions of t
            if id of s is "{uuid}" then
              select w
              select t
              select s
              return
            end if
          end repeat
        end repeat
      end repeat
    end tell''')
    time.sleep(0.5)
    landed, _ = osa("tell application \"iTerm\" to return id of current session of current window")
    check("iTerm2 jump lands on the target session, not the other", landed == s2,
          f"target {s2[:8]} got {landed[:8]}")
    check("iTerm2 target differs from the decoy", s1 != s2)
    osa('tell application "iTerm" to quit')


# ---- Terminal.app: match on the controlling tty, exactly as HostTerminal does ----
def test_terminal():
    if not installed("Terminal"):
        print("Terminal: not installed, skipped"); return
    ran.append("Terminal")
    osa_script('''
    tell application "Terminal"
      activate
      do script "echo $(tty) > /tmp/ai-e2e-term1.txt"
      delay 0.5
      tell application "System Events" to keystroke "t" using command down
      delay 0.5
      do script "echo $(tty) > /tmp/ai-e2e-term2.txt" in front window
    end tell''')
    time.sleep(1.5)
    try:
        tty1 = open("/tmp/ai-e2e-term1.txt").read().strip()
        tty2 = open("/tmp/ai-e2e-term2.txt").read().strip()
    except OSError:
        check("Terminal opened two tabs", False); osa('tell application "Terminal" to quit'); return
    # tab 2 is frontmost; jump to tab 1 by its tty
    osa_script(f'''
    tell application "Terminal"
      activate
      repeat with w in windows
        repeat with t in tabs of w
          if tty of t contains "{tty1}" then
            set selected of t to true
            set index of w to 1
            return
          end if
        end repeat
      end repeat
    end tell''')
    time.sleep(0.6)
    landed, _ = osa('tell application "Terminal" to return tty of selected tab of front window')
    check("Terminal jump lands on the target tab, not the other", landed == tty1,
          f"target {tty1} got {landed}")
    check("Terminal target differs from the decoy", tty1 != tty2)
    osa('tell application "Terminal" to quit')


# ---- Warp: resolution only (the focus URL has no scripting read-back) ----
def test_warp():
    if not installed("Warp"):
        print("Warp: not installed, skipped"); return
    ran.append("Warp")
    # A live Warp shell exports WARP_FOCUS_URL; the selftest checks resolution against live
    # agents. Here we just confirm the scheme the jump opens is well-formed if present.
    import os
    url = os.environ.get("WARP_FOCUS_URL", "")
    if url:
        check("Warp focus URL is warp://session/<uuid>",
              url.startswith("warp://session/") and len(url) > len("warp://session/"))
    else:
        print("  Warp: no WARP_FOCUS_URL in this shell (run from a Warp tab to check); skipped")


if __name__ == "__main__":
    print("=== per-terminal jump E2E ===")
    test_iterm()
    test_terminal()
    test_warp()
    print()
    print(f"terminals exercised: {', '.join(ran) or 'none'}")
    print(f"RESULT: {len(fails)} failure(s)" + (": " + ", ".join(fails) if fails else " — all green"))
    sys.exit(1 if fails else 0)
