# Installing Agent Island

Agent Island runs on **macOS 14 Sonoma or later**, on Apple silicon and Intel. It needs no Xcode,
no account and no API key.

- [1. Install](#1-install)
- [2. First launch](#2-first-launch)
- [3. Per-agent setup](#3-per-agent-setup)
- [4. Exact-tab jumps in your terminal or editor](#4-exact-tab-jumps-in-your-terminal-or-editor)
- [5. Updating](#5-updating)
- [6. Uninstalling](#6-uninstalling)
- [7. Troubleshooting](#7-troubleshooting)

## 1. Install

### Homebrew (recommended)

```bash
brew install tiwari1999/tap/agent-island
agent-island
```

- `brew install` **builds the app on your Mac** in about a minute. A locally built app is never
  quarantined, so it opens with **no Gatekeeper warning**, and no Apple notarization is involved.
- `agent-island` finishes the install. Homebrew cannot write outside its own folder, so this
  step copies the app to `~/Applications`, adds the agent hooks, sets up the login item and
  starts the app.
- To update, run `brew upgrade agent-island && agent-island`.

### From source

`install.sh` checks what the build needs before it starts and fixes it on the spot:

- **Command Line Tools missing:** it opens Apple's installer, waits for it, then carries on.
- **Swift too old:** it installs the newer Command Line Tools from Software Update (macOS asks
  for your password), then carries on.
- **Command Line Tools half-upgraded** (no SDK can build the app): it offers to reinstall them.
- **macOS older than 14:** it stops and says so, because a script cannot upgrade macOS.

Run without a terminal (for example from CI), it prints the exact command instead of prompting.



```bash
git clone https://github.com/Tiwari1999/Agent-Island.git
cd Agent-Island
./install.sh
```

`install.sh`:

1. Builds a release binary. It takes about a minute the first time.
2. Assembles `~/Applications/AgentIsland.app`.
3. Registers the hooks for every agent it finds (see [section 3](#3-per-agent-setup)).
4. Registers a login item.
5. Launches the app.

Run it again at any time; it is safe to repeat and changes only what is out of date.

A downloaded DMG will come later, once releases are notarized. An un-notarized DMG is blocked on
first launch: open it once, then go to **System Settings → Privacy & Security** and click
**Open Anyway**.

## 2. First launch

The notch shows a short welcome. It covers:

- where Agent Island reads from;
- what it can do for the agents you actually have;
- one click each to install hooks and to allow notifications.

Settings brings the welcome back.

macOS asks for **notification permission** once. That is all monitoring needs: no Screen
Recording, no Full Disk Access, and no Accessibility for any jump. Other prompts appear only when
you use the matching feature:

| When | macOS asks for | Why |
|---|---|---|
| First jump into **iTerm2** or **Terminal.app** | Automation (control that app) | Their tab-focus API is AppleScript |
| First jump into a **VS Code** or **Cursor** terminal | VS Code's own dialog, *"Allow … to open this URI?"* | Tick **Do not ask me again**. Its handler only runs after you answer. |
| Replying from the notch to an **idle** session | Accessibility | The reply has to be pasted into the terminal (⌘V). Decline it and the reply goes to your clipboard instead. |

## 3. Per-agent setup

`install.sh` picks up every agent it finds, so there is nothing to configure by hand.

| Agent | What the installer changes | What you get |
|---|---|---|
| **Claude Code** | Hook entries in `~/.claude/settings.json`, plus a `statusLine`. An existing statusLine is kept and run inside ours, not replaced. | Every feature, including approvals, answers, quota and burn rate |
| **Codex** | Hook entries in `~/.codex/hooks.json`. Codex runs new or changed hooks only after you approve them: run `codex`, type `/hooks`, trust the Agent Island entries | Sessions, status, Codex rate limits |
| **Cursor** (agent) | Hook entries in `~/.cursor/hooks.json` | Sessions and status |
| **Gemini CLI** | Hook entries in `~/.gemini/settings.json`. Gemini runs them only in folders you trust: run `gemini` in your project and trust it when asked | Sessions and status. **No approvals**: Gemini's hooks can deny a tool but never grant one. |
| **OpenCode** | Plugin file `~/.config/opencode/plugins/agentisland-opencode.js` | Sessions, status and **approvals** from the notch |

Restart any agent session that was already running when you installed: the Cursor CLI, Gemini
CLI and OpenCode read hooks only when a session starts. Claude Code and the Cursor editor reload
them by themselves. Installing with an AI agent? The [README](../README.md#one-step-after-installing)
has a prompt to paste.

The installer backs up every file it edits before changing it, with a timestamp. It never
rewrites or reorders other tools' entries. An agent that isn't installed is skipped. If you
install one later, run `./install.sh` again.

## 4. Exact-tab jumps in your terminal or editor

Clicking a row lands on the **exact** tab the agent runs in:

| Where the agent runs | Exact tab? | Needs |
|---|---|---|
| Warp, iTerm2, Terminal.app | ✅ | nothing |
| kitty | ✅ | `allow_remote_control yes` in `kitty.conf` |
| WezTerm | ✅ | the `wezterm` CLI on your `PATH` |
| tmux (in any terminal) | ✅ | nothing |
| **VS Code** terminal | ✅ | The *Agent Island* extension, which `install.sh` installs into VS Code |
| **Cursor** terminal | ✅ tab; a background Cursor window may not come to the front | The same extension, installed into Cursor |
| **Ghostty** | ✅ only on Ghostty builds that report each terminal's tty (newer than 1.3); window-only on 1.3.x | nothing |
| Anything else | Brings the app forward | The row's tooltip says why the jump isn't exact |

To skip the editor extension, run `AGENTISLAND_SKIP_IDE_EXTENSION=1 ./install.sh`.

## 5. Updating

- **Homebrew:** run `brew upgrade agent-island && agent-island`.
- **From source:** run `git pull && ./install.sh`.
- **Release builds:** they check `agentisland.in` at most once a day and ask before installing
  anything. Two places control this:
  - Settings → *Check for updates* turns it off or checks right away.
  - Right-clicking the menu-bar icon offers *Check for Updates…*.

## 6. Uninstalling

**From source:**

```bash
python3 scripts/uninstall-hooks.py     # removes only our entries, restores your statusLine
rm -rf ~/Applications/AgentIsland.app
```

**Homebrew:**

```bash
python3 "$(brew --prefix agent-island)/libexec/scripts/uninstall-hooks.py"   # first, while it is still installed
brew uninstall agent-island
rm -rf ~/Applications/AgentIsland.app
```

`brew upgrade` keeps your hooks.

## 7. Troubleshooting

**The build fails with `no installed SDK compiles SwiftUI` and prints a compiler error.** `./install.sh`
offers to reinstall the Command Line Tools for you. Read the compiler error: it names the real cause.

The usual cause is a Command Line Tools install that was only half upgraded, with leftover files
from an older Swift version. Reinstall them cleanly:

```bash
sudo rm -rf /Library/Developer/CommandLineTools
xcode-select --install
```

You do **not** need Xcode.

**A session doesn't appear.**
- Is its agent listed in [section 3](#3-per-agent-setup)?
- Did `install.sh` print "not installed, skipped" for it? If so, run `./install.sh` again now
  that the agent is installed.
- Rows for finished sessions disappear after a while; that is expected.

**Claude quota or burn rate is empty.** Claude Code only writes these while a session is running,
through the status line. Start or continue a Claude session and they appear.

**A jump only brings the app forward.** Hover over the row: the tooltip says why. For VS Code or
Cursor, check that you answered the *Allow … to open this URI?* dialog.

**A renamed Claude session shows its old name.** Run `git pull && ./install.sh`. Renames are read
from v0.5.0 on.

**Still stuck?** [Open an issue](https://github.com/Tiwari1999/Agent-Island/issues) with the last
lines of `/tmp/agentisland.log`.
