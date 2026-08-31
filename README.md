<div align="center">

# 🏝️ Agent Island

**Your MacBook notch, turned into mission control for every coding agent you run.**

Claude Code · Codex · Cursor — one panel, at a glance · jump to the exact terminal tab · approve and answer without leaving the notch

[![Platform](https://img.shields.io/badge/macOS-14%2B-000000?style=flat-square&logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-6.0-F05138?style=flat-square&logo=swift&logoColor=white)](https://swift.org)
[![No Xcode](https://img.shields.io/badge/Xcode-not%20required-4BC51D?style=flat-square)](https://www.swift.org/getting-started/)
[![Tests](https://img.shields.io/badge/self--tests-126-4BC51D?style=flat-square)](tests/selftest.py)
[![Licence](https://img.shields.io/badge/licence-MIT-blue?style=flat-square)](#-licence)

</div>

---

> [!NOTE]
> Everything runs locally. No server, no telemetry, no API key, no subscription.
> Agent Island reads only what your agents already write to your own disk.

<div align="center">
  <img src="docs/panel.png" alt="Agent Island expanded panel: quota header and four live agent sessions" width="844">
  <br>
  <sub>Quota and burn rate up top · one row per agent with its model, terminal, context ring, last instruction and live tool call</sub>
</div>

## 🤔 Why

Running five to ten coding agents at once — Claude Code in one Warp tab, Codex in another, a Cursor
chat on a third project — the bottleneck stops being the agents. It becomes **you**.

Which one is blocked? Which is quietly burning the 5-hour window? Which of nine identical terminal tabs did that notification come from? Each agent knows its own answer, and none of them shows you.

Agent Island puts the answer where your eyes already are.

## ✨ Features

### 👀 See
| | |
|---|---|
| 🧩 **Every agent** | Claude Code, Codex and Cursor in one list, each labelled with its own vendor |
| 📋 **Live sessions** | Title, project, model, terminal and the tool call happening right now |
| 🎯 **Task progress** | `4/9` with the current step, from Claude's own task list |
| 🧠 **Context pressure** | A per-session ring — compact *before* the cliff, not after |
| ⚡ **Quota** | 5h and 7d windows, a measured burn rate, and projected exhaustion |
| 💀 **Died vs finished** | A rate-limited session shows as dead, not complete |
| 🧊 **Blocked, not shouting** | Agents stuck on an old question stay visible without crying wolf |

### 🚀 Act
| | |
|---|---|
| 🎬 **Precise jump** | Click a row → land on that agent's **exact Warp tab**, not just the app |
| ✅ **Approve from the notch** | Permission cards, answered with `⌘⌥A` / `⌘⌥D` |
| 💬 **One-click answers** | Multiple-choice prompts answered with `⌘⌥1`–`⌘⌥4` |
| 🤖 **Auto-approve rules** | A regex allowlist that governs every agent — one rule covers Claude's `Bash` and Cursor's `Shell` alike |
| 🔔 **Alerts that respect you** | Desktop notifications only when you're *not* already looking |

## 🧭 The Warp jump

The interesting part. 👇

Other notch apps resolve Warp tabs by reading `warp.sqlite` and driving a **keystroke loop**, because the `warp://action/*` scheme is a closed whitelist that rejects focus intents. That approach can't tell apart tabs that share a working directory — so if all your agents live in one monorepo, it lands on the wrong one. Agent Island reads nothing from Warp's database: the session handle comes from the agent process's own environment, so there is no permission to grant and nothing to break when the schema changes.

But Warp exports a per-session handle into every shell it spawns:

```bash
WARP_TERMINAL_SESSION_UUID=936130df75f04ef3937afb799bdb1946
WARP_FOCUS_URL=warp://session/936130df75f04ef3937afb799bdb1946
```

Opening that URL makes Warp fire a `handle_pane_navigation_event` and focus the tab. So the whole jump is:

```
claude agents --json  →  pid  →  WARP_FOCUS_URL from that process's env  →  open
```

🗄️ No database. ⌨️ No synthetic keystrokes. 🔓 No Accessibility permission. And it resolves correctly **even when every tab shares one repo** — measured at 6/6 distinct tabs.

## 📦 Install

```bash
git clone https://github.com/Tiwari1999/Agent-Island.git
cd Agent-Island
./install.sh
```

`install.sh` builds a release binary, assembles `~/Applications/AgentIsland.app`, registers the hooks, and launches it.

<details>
<summary>🔧 Build only, without installing</summary>

```bash
swift build -c release
```

Xcode is **not** required — Command Line Tools are enough.
</details>

### Requirements

- 🍎 macOS 14+
- 🤖 At least one of Claude Code, Codex or Cursor — whichever are installed are picked up automatically
- 🖥️ Warp — for the precise-jump feature (everything else works without it)

### What each agent supports

Measured, not assumed. A capability an agent does not expose is labelled on the row rather than
left blank, so an unsupported feature never reads as a broken one.

| | Claude Code | Codex | Cursor |
|---|---|---|---|
| Session list | ✅ | ✅ | ✅ |
| Live tool activity | ✅ | ✅ | ✅ |
| Approve from the notch | ✅ | ✅ | ✅ |
| One-click answers | ✅ | — | — |
| Context pressure | ✅ | ✅ | — |
| Quota and burn rate | ✅ | — | — |
| Task progress | ✅ | — | — |
| Precise jump | ✅ | ✅ | ✅ |
| Resume when stopped | ✅ | ✅ | ✅ |

## 🪝 Hooks

Agent Island listens to each agent's hook events. Claude Code and Codex share a `hooks.json`
schema; Cursor uses its own event names, which are folded onto one vocabulary internally so a
`Bash` rule also governs a `Shell` call.

| Hook | Powers |
|---|---|
| `PreToolUse` / `PostToolUse` | live activity per session |
| `Notification` | an agent genuinely needs you |
| `Stop` / `SessionEnd` | completion toast |
| `StopFailure` | died-vs-finished, with `error_type` |
| `PermissionRequest` | approval cards + auto-approve rules |
| `PreToolUse` (`AskUserQuestion`) | one-click answers |
| `statusLine` | quota, model, per-session context window |

> [!IMPORTANT]
> **Every hook fails open.** If the app isn't running, or you don't answer in time, or a rules file is malformed, the hook exits silently and Claude prompts you normally.
> A hook that hangs would freeze your session — so none of them can.

The `statusLine` wrapper runs your **existing** statusline unchanged inside it, and hook registration never clobbers another tool's entries. 🤝

## 🤖 Auto-approve rules

`~/.agentisland/rules.json` — consulted *before* you're ever asked:

```json
[
  {"tool": "Bash", "pattern": "^git (status|diff|log|show)\\b", "action": "allow"},
  {"tool": "Bash", "pattern": "^npm test$", "cwd": "/Users/me/project", "action": "allow"},
  {"tool": "Read", "pattern": ".", "action": "allow"}
]
```

`tool` and `cwd` are optional; `pattern` is a regex over the command or file path. Anything that doesn't match falls through and still asks. ✋

## 🏗️ Architecture

```
Claude Code ─hooks──┐
Codex       ─hooks──┼───> /tmp/agentisland-events.jsonl ──tail──> HookStream
Cursor      ─hooks──┘

Claude Code ──statusLine──> /tmp/agentisland-status/<id>.json ───> StatusStore
Claude ──agents --json──┐
Codex  ──rollout files──┼──────────────────────────────────────> AgentStore
Cursor ──chats/meta.json┘
                                                                            │
                                       approvals / answers <──decision file─┘
```

Two design rules earned the hard way:

- 🪟 **The window is created once at maximum size and never resized.** The window server can't interpolate content across a live resize, so every bit of motion happens inside SwiftUI.
- 🖱️ **Hover uses an `NSTrackingArea`, never polling.** A 32pt strip is crossed in under 40 ms — faster than any practical poll interval, so polling misses it more often than it catches it.

## 🧪 Tests

```bash
python3 tests/selftest.py
```

126 checks: jump resolution against live Warp tabs, every hook contract (including that each failure path exits without blocking), auto-approve decisions, panel geometry, the staleness window, and that the panel holds only real sessions — every vendor present on disk reaches it, no row is labelled with a bare session id, and no test data survives.

## 📄 Licence

MIT

<div align="center">
<sub>Built for people running more agents than they have eyes. 👀</sub>
</div>
