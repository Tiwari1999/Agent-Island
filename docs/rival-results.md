# Rival routing results — the shared-cwd bed

Bed: six real Claude Code sessions, each in its own Warp tab, all in one repository
directory. Ground truth per session is its own `WARP_FOCUS_URL`; the landing oracle is
a screenshot of Warp's sidebar after each jump. Protocol in `tests/rival.py`.

| App | Version | Landed | Saw the bed | Mechanism (from its own binary) |
|---|---|---|---|---|
| **Agent Island** | HEAD | **6/6** | 6/6 sessions | `WARP_FOCUS_URL` from the agent process's environment |
| Open Island | 1.1.8 | 0/6 | 6/6 shown, 5 labeled "Unknown" terminal | `warp.sqlite` + keystroke loop ("Warp tab advance") |
| CodeIsland | 1.0.32 | 0/3 | **1/6 sessions** (hook-driven discovery; idle sessions never appeared in 25 min) | `WarpPaneResolver` over `warp.sqlite` (cwd-keyed); AppleScript tty-match for iTerm2/Ghostty only |
| Vibe Island | — | untested | — | untested ($19.99 purchase required) |

Dates: Open Island 2026-09-01, CodeIsland 2026-09-01.

Fairness caveats, recorded rather than hidden:
- Clicks were synthetic (HID-level); both rivals' other controls demonstrably respond to the
  same events (AXPress visibly works), but a physical click was not tested.
- CodeIsland never fired an Automation TCC prompt during any trial, i.e. it never attempted
  Apple Events; its fully-granted permission path (Full Disk Access + Automation) was not
  exercised. On this bed even a working cwd-keyed resolver has six identical candidates.
- CodeIsland also silently appended its hook to 11 events in `~/.claude/settings.json` on
  first launch, without a prompt. Restored from snapshot afterwards; nothing of it remains.
