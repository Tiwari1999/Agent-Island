# AgentIsland

A macOS notch panel for Claude Code. See every session at a glance, jump to the exact terminal
tab that needs you, and approve or answer a blocked agent without leaving the notch.

Native Swift/SwiftUI. No Electron, no server, no telemetry, no API key — everything is read from
files Claude Code already writes on your machine.

<!-- Add a screenshot or short GIF of the expanded panel here. -->

## Why

Running five to ten concurrent Claude Code sessions, the bottleneck stops being the agents and
becomes *you*: which one is blocked, which is burning quota, and which terminal tab does this
notification even belong to. Claude Code exposes enough to answer all three — it just doesn't
surface it anywhere.

## Features

- **Live session list** — every agent with its title, project, model, terminal, and current tool call
- **Precise jump** — click a row and land on that agent's exact Warp tab, not just the app
- **Approve from the notch** — permission requests appear as a card; `⌘⌥A` / `⌘⌥D`
- **Answer questions in one click** — multiple-choice prompts answered with `⌘⌥1`–`⌘⌥4`
- **Auto-approve rules** — regex allowlist so routine commands never interrupt you
- **Quota** — 5h and 7d windows, plus a measured burn rate and projected exhaustion
- **Context pressure** — a per-session ring, so you can compact before the cliff instead of after
- **Task progress** — `4/9` with the current step, from Claude's own task list
- **Died vs finished** — a rate-limited session is shown as dead, not complete
- **Desktop alerts** — only when you're not already looking at the terminal

## How the Warp jump works

The interesting bit. Other notch apps resolve Warp tabs by reading `warp.sqlite` and driving a
keystroke loop, because the `warp://action/*` scheme is a closed whitelist that rejects focus
intents. That approach cannot disambiguate tabs sharing a working directory.

Warp exports a per-session handle into every shell it spawns:

```
WARP_TERMINAL_SESSION_UUID=936130df75f04ef3937afb799bdb1946
WARP_FOCUS_URL=warp://session/936130df75f04ef3937afb799bdb1946
```

Opening that URL makes Warp fire a `handle_pane_navigation_event` and focus the tab. So the whole
jump is: read the agent's pid from `claude agents --json`, read `WARP_FOCUS_URL` out of that
process's environment, and `open` it. No database, no synthetic keystrokes, no Accessibility
permission — and it works even when every tab shares one repo.

## Requirements

- macOS 14+
- Claude Code (`claude` on your `PATH`)
- Warp, for the precise-jump feature (everything else works without it)
- Swift toolchain — Xcode **not** required; Command Line Tools are enough

## Install

```bash
git clone https://github.com/Tiwari1999/agentisland.git
cd agentisland
./install.sh
```

`install.sh` builds a release binary, assembles `~/Applications/AgentIsland.app`, registers the
hooks in `~/.claude/settings.json`, and launches it. To build only:

```bash
swift build -c release
```

## Hooks

The app reads Claude Code's hook events. `install.sh` registers these:

| Hook | Used for |
|---|---|
| `PreToolUse` / `PostToolUse` | live activity per session |
| `Notification` | an agent needs you |
| `Stop` / `SessionEnd` | completion toast |
| `StopFailure` | died-vs-finished, with `error_type` |
| `PermissionRequest` | approval cards (and the auto-approve rules) |
| `PreToolUse` (`AskUserQuestion`) | one-click answers |
| `statusLine` | quota, model, and per-session context window |

Every hook **fails open**: if the app isn't running, or you don't answer in time, or a rules file
is malformed, the hook exits silently and Claude prompts you normally. A hook that hangs freezes
the session, so none of them can.

The `statusLine` wrapper runs your existing statusline unchanged inside it.

## Auto-approve rules

`~/.agentisland/rules.json` — checked before you're asked:

```json
[
  {"tool": "Bash", "pattern": "^git (status|diff|log|show)\\b", "action": "allow"},
  {"tool": "Bash", "pattern": "^npm test$", "cwd": "/Users/me/project", "action": "allow"},
  {"tool": "Read", "pattern": ".", "action": "allow"}
]
```

`tool` and `cwd` are optional; `pattern` is a regex over the command or file path. Anything that
doesn't match falls through and still asks.

## Architecture

```
Claude Code ──hooks──> /tmp/agentisland-events.jsonl ──tail──> HookStream
            ──statusLine──> /tmp/agentisland-status/<session>.json ──> StatusStore
            ──claude agents --json──────────────────────────────────> AgentStore
                                                                          │
                                     approvals/answers <──decision files──┘
```

One `NSPanel` is created at maximum size and **never resized** — the window server cannot
interpolate content across a live resize, so all motion happens inside SwiftUI. Hover uses an
`NSTrackingArea` in a separate sensor window rather than polling; a 32pt strip is crossed in under
40ms, well inside any practical poll interval.

## Tests

```bash
python3 tests/selftest.py
```

65 checks covering jump resolution against live Warp tabs, the hook contracts (including that
every failure path exits without blocking), auto-approve rule decisions, panel geometry, and the
staleness window.

## Licence

MIT
