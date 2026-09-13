# AgentIsland — session handoff (2026-09-14)

Repo: `~/PersonalProjects/agentisland` · GitHub `Tiwari1999/Agent-Island` (MIT) · branch `main`
Install: `./install.sh` (builds + relaunches). App bundle id: `sh.emergent.agentisland`
(prefs: `defaults … sh.emergent.agentisland`; **pkill first, then write, then launch** — a
running app clobbers prefs on quit). Diagnostics log: `/tmp/agentisland.log`.

## THE OPEN BUG — fix this first

User reports, twice, after three fix rounds: **row clicks still route wrongly.** Latest wording:
"every second chat is opening my terminal, the first chat is opening Invoke" (sic — unclear what
Invoke is; warp:// scheme verified to resolve to /Applications/Warp.app, single install, bundle
`dev.warp.Warp-Stable`, binary literally named `stable`).

State of diagnosis:
- `claude agents --json` shows 19 sessions, 17 with pid (all Warp, real ttys), 2 without
  (genuinely dead background agents → Terminal resume is CORRECT for those two).
- The APP does its own pid binding (ClaudeSource argv scan + hook fallback in
  `AgentStore.rebuild`). The CLI numbers do NOT prove the app's rows carry pids. **Nobody has
  yet looked at what the app's own rows resolve to.** That is the next step.
- `jump()` is now instrumented — every click logs
  `jump <sid> pid=<n|nil> host=<name>` then `-> focused …` / `-> host.jump() failed …` /
  `-> dead session, reopening in Terminal` to /tmp/agentisland.log. **Ask the user to click 3-4
  rows, then read the log.** That names the bad branch immediately — do this before touching code.
- A synthetic click harness exists: `/Users/tiwari/.claude/jobs/c63338f6/tmp/clickrows.swift`
  (hover notch → click at y → report frontmost). Its row-y guesses (85/150/218/287) missed the
  rows; screenshot the open panel first and calibrate. Pointer restore is built in.
- Suspects, in order: (1) the app's rows carry `pid=nil` where the CLI has pids — then every
  such row is "dead" → Terminal resume — check `AgentStore.rebuild`/ClaudeSource binding, incl.
  Sumit's PR #3 claim (`Proc.pids(comm:)` exact-match; on THIS machine p_comm == "claude" so it
  *should* bind, but verify in-app, not via ps); (2) `.warp` host.jump() "succeeds"
  (NSWorkspace.open returns true) but Warp doesn't switch tab — pre-existing, NOT a regression;
  (3) row identity is fine (`id = sessionId`, checked).

History of this bug (all three were mine, all shipped, all verified only against their own
symptom — the lesson is in the last commit message `73edfd2`):
1. `ad47621` removed the pid gate → live rows opened Terminal. Re-gated.
2. `73cf061` no-tty → .degraded → THIS chat's row went nowhere. Fixed by walking the process
   tree: `Proc.ancestorWithTTY` resolves a background agent to the interactive session that
   spawned it (9154→9077→8982→52686/ttys007, verified).
3. Auto-hide faded the bar while agents were working. Now gated on
   working==0 && waiting==0 && blocked==0.

Guards now in the suite (runtime, over live sessions): "every live agent has somewhere to jump
to", "each interactive agent maps to a DISTINCT tab" (background agents legitimately share their
owner's tab), "a background agent resolves the terminal that owns it".

## What shipped in this session (all pushed to main, all green)

- **Settings screen** (gear in panel header): material solid/sleek, typeface mono/clean/round
  (default clean), bar auto-hide never/4s/8s, quiet 30m/1h/4h (hides bar + suppresses
  peek/approval/question cards; system notifications still fire; panel you open yourself is
  NEVER hidden — that was a lockout bug, fixed), Quit (only quit path — app is LSUIElement).
- **Type scale**: 12 sizes (7–12.5pt, 54% ≤9pt) → `Type.micro/small/body/title` = 10/11/12/13.
  No view sets a raw text size (mutation-tested guard). Glyphs 9/10pt.
- **TerminalWrite** (`Sources/AgentIsland/TerminalWrite.swift`): reply-to-session from the
  console composer. iTerm `write text`, Terminal `do script in t`, kitty/wezterm CLIs, and
  **tmux `send-keys -l`** (the Return is a separate key; `-l` verified to deliver "Enter C-c
  Escape BSpace" as text). In-process NSAppleScript so the TCC prompt is attributed to us.
  **Warp: no write path exists** (verified none of 6 rival repos has one either). All the
  user's sessions are in Warp → composer shows "takes no input from here". tmux is the answer;
  user hasn't adopted tmux yet.
- **tmux host** (`.tmux(pane:outerBundle:)`): resolved AHEAD of terminal checks from TMUX_PANE;
  jump = switch-client + select-window + select-pane + raise outer app. `tmuxSafe` sanitiser —
  **appleSafe strips `%` and would turn pane `%3` into window 3** (caught pre-ship).
- **Blocked badge**: interactiveLineage keeps chats unbadged at any delay; dormancy grace 60s;
  truth-table test `tests/blocked_badge.py`, all 3 historical regressions mutation-tested.
- **Display**: no-notch screens (mirroring/DELL) — bar auto-hides + hover-returns; measured via
  screen-luminance sampling (bar 9.9 → hidden 50.5 → hover 0.0). `didChangeScreenParameters`
  observer added (was missing entirely — mirroring never re-measured).
- **Dead sessions**: click → Terminal.app runs `claude --resume <id>` in the right cwd
  (osascript `do script`; Warp is not scriptable). validID guards the id (injection closed:
  0/11 hostile accepted, ids from transcripts are untrusted input).
- **Console**: read view (phase 1) + markdown tables + back-to-list `‹ agents` + composer.
- Review rounds: 28 findings fixed across two /code-review passes. Suite: **fully green**,
  ~540 checks incl. the one that was red for weeks (real bug: background agent claimed its
  daemon-launcher's Warp tab — now walks to owner).

## Competitor intel (cloned under /Users/tiwari/.claude/jobs/c63338f6/tmp/rivals — job dir,
may be cleaned; re-clone if needed)

Market: crowded. CodeIsland (2.4k★, 15 agents, MIT), Vibe Island ($19.99, 26 agents),
xisland/MioIsland/agent-island (name collision! ymxfl/agent-island exists), so-agentbar,
claude-status, ClaudeBar. Licences: CodeIsland/so-agentbar MIT, claude-status BSD,
agent-island Apache-2 (code OK w/ attribution); **MioIsland CC BY-NC — techniques only, never
copy code**; ClaudeBar NO licence — same.

Copy list, in value order for THIS user: (1) DONE tmux; (2) smart notification suppression
(CodeIsland TerminalVisibilityDetector — 2 tiers, app-frontmost free / tab-visible 50-200ms bg
only); (3) quick reply phrases on question cards; (4) keep-awake while agents run; (5) git
branch per session row; (6) project grouping (flat 19-row list today); (7) Warp PANE resolution
(CodeIsland WarpPaneResolver); (8) real Cursor quota (so-agentbar CursorUsageProvider).

## Known debts / next after the bug

- **Distribution is the real blocker**: ad-hoc signed, no notarization, no release, no Homebrew.
  NotchBay markets its notarization against Boring Notch's Gatekeeper wall. Also bundle id is
  employer domain on a personal project.
- HIG fixes not yet done: 23 onTapGesture → 0 Button (no keyboard/VoiceOver/press states);
  `faint` contrast 3.12:1 on solid, and 5 sites dim it further to ~2:1 (console stamp 1.99:1);
  status-item NSMenu (Open/Settings/Quit); status icon never reflects state; `symbolEffect
  (.pulse` at Views.swift:826 ignores reduceMotion. Do NOT add .ultraThinMaterial — user
  rejected glass blur; Droppy measured opaque #000.
- Sumit's PR #3 open since Sep 10 (discovery p_comm scan). Sumit's issue #2 (Liquid Glass)
  answered, open by design. Warp tab-switch unreliability: pre-existing, unsolved.
- `Reopen` still spawns /usr/bin/osascript (works, but TCC attributes to osascript; migrate to
  NSAppleScript like TerminalWrite when touched next).

## Working rules that bit us (obey them)

- Verify every fix against the MAIN FLOW (click a row → land on session), not just the
  symptom. That failure mode shipped 3 regressions in 2 days.
- Test text-matches must anchor on code, not comments ("CGEvent" matched a comment; use
  "CGEvent(").
- python .replace() on Swift: match FULL indentation or it hits substrings (mangled costChip
  once; build stayed green — ViewBuilder swallows garbage).
- Mutation-test new assertions (assert the mutation LANDED before trusting "caught").
- Restore mutated files immediately; a crashed harness once left the tree mutated.
- `defaults` bundle id: extract with PlistBuddy, never `tr -d '<string>'` (that deletes chars).
- Screenshots: verify by pixel-sampling, not eyeballs (opacity-on-content bug read as "gone"
  at lum 0.0 when an opaque black block still covered the tabs — fade the SHELL).
- cursor-task: refuses untrusted dirs; don't grant trust to cloned third-party repos. Named
  premium models now ALLOWED for important calls (user 2026-09-13, memory updated).
- User rules: no Claude subagents unless asked; comments ≤2 lines (hook enforces); branches
  feat/|fix/|change/; don't report token tallies.
