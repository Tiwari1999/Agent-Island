<div align="center">

# 🏝️ Agent Island

**Your MacBook notch, turned into mission control for every coding agent you run.**

Claude Code · Codex · Cursor — one panel, at a glance · jump to the exact terminal tab · approve and answer without leaving the notch

[![Platform](https://img.shields.io/badge/macOS-14%2B-000000?style=flat-square&logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-6.0-F05138?style=flat-square&logo=swift&logoColor=white)](https://swift.org)
[![No Xcode](https://img.shields.io/badge/Xcode-not%20required-4BC51D?style=flat-square)](https://www.swift.org/getting-started/)
[![Tests](https://img.shields.io/badge/self--tests-411-4BC51D?style=flat-square)](tests/selftest.py)
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
| 🎬 **Precise jump** | Click a row → land on that agent's **exact tab** — Warp, iTerm2 or Terminal.app — not just the app |
| 💠 **Cost breakdown** | API-equivalent spend per model, today and this month — from the vendors' own token accounting |
| 📋 **Plan review** | Read the full Markdown plan and approve it from the notch, with a 55s window instead of 20 |
| 📊 **Pick your agent** | One control in the header switches which agent it reports on — that agent's own limit windows and its own spend, defaulting to whichever you use most |
| 📊 **Per-vendor limits** | Claude's 5h/7d windows and Codex's own rate limits side by side; at rest the bar shows whichever limit is closest to biting instead of just "idle" |
| 💚 **Proof of life** | The resting bar shows *what* the agent is doing, not just that it is running — the motion differs for thinking, reading, editing, running and waiting. CoreAnimation-backed, 0.15% CPU |
| 🕊 **Zero spawns at idle** | A refresh creates no processes at all — the process table, environments and working directories are read with syscalls; warm discovery of 27 sessions takes 0.08s |
| 🛰 **SSH remote monitoring** | Sessions on machines you ssh into, in the same panel — `echo my-vm >> ~/.config/agentisland/remotes`; the probe travels on stdin, nothing is installed remotely |
| ✅ **Approve from the notch** | Permission cards, answered with `⌘⌥A` / `⌘⌥D` |
| 💬 **Answer questions** | `AskUserQuestion` prompts answered in the notch: multiple choice with `⌘⌥1`–`⌘⌥4`, a **free-text** field for your own answer, and multi-question asks sequenced with clickable pips (`⌘⌥⇧1`–`⌘⌥⇧4` to jump). Nothing sends until you press **submit** |
| ⏳ **Sliding window** | A visible countdown before an unanswered question hands back to the terminal; every interaction pushes it forward, so answering never times out under you |
| 💬 **Or answer in the chat** | One click releases the turn so Claude's own picker appears in the terminal, and the notch keeps a read-only copy — the question stays visible in both places |
| 🤖 **Auto-approve rules** | A regex allowlist that governs every agent — one rule covers Claude's `Bash` and Cursor's `Shell` alike |
| 🔔 **Alerts that respect you** | Desktop notifications only when you're *not* already looking |

## 🧭 The precise jump

The interesting part. 👇 (Warp is the neat case; iTerm2 and Terminal.app work too — the table below.)

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

The same idea generalises: the handle for *every* terminal comes from the agent process's own environment, and each is focused by that terminal's real API — no keystroke loops anywhere.

| Terminal | Handle (from the process env) | How it's focused | Permission |
|---|---|---|---|
| Warp | `WARP_FOCUS_URL` | open the `warp://session/…` URL | none |
| iTerm2 | `ITERM_SESSION_ID` (`wNtNpN:UUID`) | AppleScript `select` the session whose id is that UUID | Automation, asked once |
| Terminal.app | the process's controlling **tty** (read by syscall) | AppleScript select the tab whose `tty` matches | Automation, asked once |

The two subtle bugs worth calling out, because they read as "the jump is broken": iTerm2's env handle carries a `wNtNpN:` pane prefix its scripting id does **not**, so a whole-string match never hit — the fix matches on the UUID. And Terminal.app's `TERM_SESSION_ID` is a UUID it never surfaces in AppleScript, so the only usable handle is the controlling tty, read from the process by syscall. Both are covered by `tests/terminals-e2e.py`, which opens two real sessions per terminal and proves the jump lands on the intended one, not its neighbour.

## 💬 Answering from the notch

When Claude asks an `AskUserQuestion` — the multiple-choice prompts, including the ones with a
preview panel and the multi-question asks — the card comes to the notch and you answer it there:
`⌘⌥1`–`⌘⌥4`, a free-text field for your own answer, pips to move between questions, **submit** to
send. Nothing is sent until you press it.

The honest part: the terminal and the notch **cannot both be live at once**. A Claude Code hook
runs *before* the picker is drawn, so while the notch holds the answer the terminal shows nothing —
and once the hook lets go, the terminal owns the picker and the notch can't reach into it. So the
notch takes first crack with a **sliding window**: a visible countdown, pushed forward by every
interaction, that hands the turn back to the terminal if you go idle. Want the terminal instead?
**answer in chat →** releases it immediately and keeps the card up as a read-only copy, so the
question is visible in both places. 🪟 One place is interactive at a time — by design, not by
accident.

## 📦 Install

```bash
git clone https://github.com/Tiwari1999/Agent-Island.git
cd Agent-Island
./install.sh
```

`install.sh` builds a release binary, assembles `~/Applications/AgentIsland.app`, registers the hooks, and launches it.

macOS asks once for **notification permission** on first launch. That is all monitoring needs —
no Accessibility, no Screen Recording, no Full Disk Access. The one extra prompt is on your first
**jump into iTerm2 or Terminal**: macOS asks to let Agent Island *control* that app, because their
focus APIs are AppleScript. Jumping into **Warp needs no permission at all** — it is a URL open.

<details>
<summary>🧹 What it touches, and how to undo it</summary>

It appends hook entries to `~/.claude/settings.json` and, where present, `~/.codex/hooks.json` and
`~/.cursor/hooks.json` — timestamped backup first, other tools' entries never rewritten or
reordered. If you already have a `statusLine`, it is saved and run inside ours rather than replaced.

```bash
python3 scripts/uninstall-hooks.py     # removes only our entries, restores your statusLine
rm -rf ~/Applications/AgentIsland.app
```
</details>

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
- 🖥️ A supported terminal for the **precise jump** — Warp, iTerm2, or Terminal.app (everything else works without one). Other terminals raise the app; the row says when a jump can't be precise

### What each agent supports

Measured, not assumed. A capability an agent does not expose is labelled on the row rather than
left blank, so an unsupported feature never reads as a broken one.

| | Claude Code | Codex | Cursor |
|---|---|---|---|
| Session list | ✅ | ✅ | ✅ |
| Live tool activity | ✅ | ✅ | ✅ |
| Approve from the notch | ✅ | ✅ | ✅ |
| Answer questions from the notch | ✅ | — | — |
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
| `PreToolUse` (`AskUserQuestion`) | answer questions from the notch — choice, free text, sliding window |
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

411 checks: jump resolution against live Warp tabs, the per-terminal jump handles (iTerm2's UUID-after-prefix and Terminal.app's tty, with a full round-trip in `tests/terminals-e2e.py`), every hook contract (including that each failure path exits without blocking), the full question flow (free-text answers crossing the same validation as labels, state surviving a close/reopen, the sliding grace, no answer sent until submit), auto-approve decisions, panel geometry, the staleness window, and that the panel holds only real sessions — every vendor present on disk reaches it, no row is labelled with a bare session id, and no test data survives.

## 📄 Licence

MIT

<div align="center">
<sub>Built for people running more agents than they have eyes. 👀</sub>
</div>
