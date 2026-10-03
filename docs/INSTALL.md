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

### From source (works today)

You need Apple's **Command Line Tools**. If `xcode-select -p` prints a path, you have them.
Otherwise install them:

```bash
xcode-select --install
```

Then:

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

### Homebrew or DMG (from the first release)

Once v0.5.0 is published on [GitHub Releases](https://github.com/Tiwari1999/Agent-Island/releases),
either of these will work:

```bash
brew install --cask tiwari1999/tap/agent-island
```

or download `AgentIsland-<version>.dmg` from Releases and drag it to Applications.

> **Not available yet:** neither the tap nor the release exists yet. Until they do, install from
> source.

Until releases are notarized by Apple, macOS blocks the first launch of a downloaded copy. To
allow it:

1. Open the app once and dismiss the warning.
2. Go to **System Settings → Privacy & Security** and click **Open Anyway**.

You only need to do this once. A copy built from source with `install.sh` is not quarantined, so
this does not apply to it.

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
| **Codex** | Hook entries in `~/.codex/hooks.json` | Sessions, status, Codex rate limits |
| **Cursor** (agent) | Hook entries in `~/.cursor/hooks.json` | Sessions and status |
| **Gemini CLI** | Hook entries in `~/.gemini/settings.json` | Sessions and status. **No approvals**: Gemini's hooks can deny a tool but never grant one. |
| **OpenCode** | Plugin file `~/.config/opencode/plugins/agentisland-opencode.js` | Sessions, status and **approvals** from the notch |

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

| Command | Removes the app | Removes the hooks and Application Support |
|---|---|---|
| `brew uninstall --cask agent-island` | yes | no. The hooks are left in place but inert: with no app running, each one exits immediately. |
| `brew uninstall --cask --zap agent-island` | yes | yes |

`brew upgrade` and `reinstall` keep your hooks.

## 7. Troubleshooting

**The build fails with `no installed SDK compiles SwiftUI` and prints a compiler error.** Read the
compiler error: it names the real cause.

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
