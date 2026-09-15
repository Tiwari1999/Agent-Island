# AgentIsland — session handoff (2026-09-14)

Repo: `~/PersonalProjects/agentisland` · GitHub `Tiwari1999/Agent-Island` (MIT) · branch `main`
Install: `./install.sh` (builds + relaunches). App bundle id: `sh.emergent.agentisland`
(prefs: `defaults … sh.emergent.agentisland`; **pkill first, then write, then launch** — a
running app clobbers prefs on quit). Diagnostics log: `/tmp/agentisland.log`.

## THE ROUTING BUG — FIXED 2026-09-14 (ClaudeAgents pid seed)

Symptom: alternating rows don't route ("worked 2h ago"). Manifest audit
(`/tmp/agentisland.rows.json`): the failing rows are `host=background pid=-1` — a **pid-binding**
failure, not a jump/host-resolution one. Bound `--resume` rows route to Warp; interleaved bare
`claude` rows don't → every-other-row fails.

Root cause — the binding CODE did not change in 23h; the app **relaunch** broke it. A pid bind is
made in memory when a session fires a live hook (ancestor of a *fresh* `ai_ppid`). A bare `claude`
started without `--resume` and sharing a cwd (14 in `emergent/mono`) binds by nothing else, so that
live-hook bind is its only one — and startup replays just 1MB (~1h) of the spool, dropping every
idle->1h bind while the process keeps running. It "worked 2h ago" because the long-running app had
accumulated all the live binds; `install.sh`/relaunch wipes them.

The spool cannot rebuild these safely: its recorded `ai_ppid` is a dead shell whose lineage is
gone, and resolved against today's table it lands on the WRONG live claude (verified: 7 of 8
recoveries were mis-binds, e.g. `9a93fad1`→14244 which is actually `a7389f7c`). cwd-uniqueness fails
too (all share `mono`). The one authoritative source is `claude agents --json` (100% cwd/tty-
consistent, 18/18).

The fix (minimal, +51/-1 lines): `ClaudeAgents.pids(needed:)` in CursorSource.swift — a ONE-SHOT
`claude agents --json` seed taken on the first refresh that finds an unbound Claude session,
cached; every later refresh reads the cache. `AgentStore.rebuild` applies it as the last binding
step behind the existing liveness+comm guard (so a reused pid can't mis-bind). Seeds once per
launch → refresh loop stays spawn-free (selftest §9g still green). Result: bound Warp rows 8→18,
**0 mis-binds** (guard correctly leaves `9a93fad1` and the desktop/dead/subagent rows unbound).

Still `background` (correctly — `claude agents` has no live pid): 74695d32/908bcbdc (Claude desktop
app, no local terminal), 01a07ad*/9a93fad1 (subagents), edb6be00/2b83663a/… (dead).

Second fix (same session): a closed session (pid==nil, no tab to focus) was reopening in the macOS
default **Terminal**, but the user lives in Warp and wanted it back in Warp. `AgentStore.jump` still
reopens a closed session — the terminal is now a **setting** (`Prefs.reopenIn`, `ReopenTarget`
{warp, terminal}, defaults to warp when Warp is installed). `Reopen.run` honors it: **Warp** via a
**tab configuration** (`~/.warp/tab_configs/agentisland-reopen.toml` + `warp://tab_config/<name>`),
which opens a new tab in the CURRENT Warp window and runs its `commands` — a launch config
(`warp://launch`) opened a whole new WINDOW, which the user rejected; both run the exec (the old
handoff's "launch-config URL does not execute" was wrong, verified). Else Terminal.app as before.
A live tab is still focused where it runs; only a session whose tab is gone is reopened. Verified by
real clicks: row1 → Warp focus; row3 (closed 74695d32) → new Warp TAB (window count 1→1),
`claude --resume` at its cwd. Settings row: "Reopen a closed chat in · Warp / Terminal". §45 covers it.

Leftover: `agentisland-reopen.toml` lingers in the user's Warp tab-config list (reused, one file).
NOT regressions: `.warp` host.jump() returns true but Warp sometimes doesn't switch tab
(pre-existing). Real-click harness: `scratchpad/clicktest.swift` (hover bar, click row y — panel
rows at y≈95/165/235/305/375, ~70px apart on the 1920×1080 display).

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

## Usage display (2026-09-14, uncommitted with the routing work)

- **Both limit windows in the bar**, replacing the single "claude 62% left" — the weekly is the one
  that ends a workday, so showing only the 5h hid the number that actually runs out. Idle prints
  `claude left 5h 84% (2h25m) · wk 71% (3d10h) · $spend · tokens`; working prints
  `left 5h 84% wk 71%`. **"left" leads both states**: the first cut showed bare `16% · wk 29%` next
  to the working count, which read as "1 16% wk 29%" — three unrelated numbers, no unit, no
  direction. `Views.primaryQuota` returns the whole `Quota` (was a 5h-only tuple).
- **The bar's width formulas were measured against the wrong font.** `sides()` used 5.3px/char and
  `tests/restwidth.swift` measured at 8.5pt, but `Type.micro` became **10pt** in the type-scale
  refactor (707b796) where the real advance is **6.2px/char**. Every line had been ~18% over its
  box, silently clipped (the box is `.clipped()`, not truncated) — and the second quota window
  pushed it far enough to visibly WRAP onto two lines. Constants are now 6.2/char, quiet cap
  300→420, and the working side grew a `limit:` term (was a fixed 86 with no room for a second
  window). The harness measures at 10pt against the real current strings and now covers BOTH
  lines; re-running it with the old constants fails every line, so it actually catches this.
  Do NOT use `.fixedSize()` to stop wrapping here — it trades a wrap for a silent clip, which a
  suite guard forbids; size the box instead.
- **The first cut was too wide, unbalanced, and slid under the notch.** Resolved together, because
  they were one problem: (a) the reset countdowns came OUT of the bar — they doubled its width for
  a number you act on far less often, and the panel already shows one per window; (b) the notch gap
  drifts when the sides differ (the shell is centred in its window, so it moves half the
  difference) — that is what buried "1 working" under the camera housing. **Mirroring the sides to
  fix it was WRONG and was reverted**: the left holds a sentence and the right two percentages, so
  `max(l, r)` paid the sentence's width twice and grew the bar to ~727pt, half a screen. Sides are
  sized independently again (l cap 220 / r cap 310) and `Island.shellOffsetX` shifts the shell by
  `(right - left) / 2` to keep the gap on the notch. Working ~591pt, idle ~525pt (was 509 before
  any of this, with one bare percentage instead of two labelled windows). `maxSize.width` 980.
  Also: the working count prints only when >1 — a single agent is already said by the pulse, so
  "1 working" was a number to read and width to pay for. The panel's pill still shows it at 1.
  (c) An empty left beside a crowded right still reads as broken, so with nothing running the
  left carries **`spent $438 · 18.2M`** against the right's **`left 5h 74% wk 70%`** — the two
  sides pair as one sentence, spent / left, and balance each other. The quiet-vs-working render
  branches collapsed into one. Pixel-verified from a silent screencapture: content clears the
  notch by 30px both sides (notch retina x1326-1696; left ends 1296, "1 working" starts 1726).
- **The limits moved to a panel FOOTER and off the bar entirely** (2026-09-15, user's call). They
  were wedged into the panel header between the picker and the chips, and repeated on the bar where
  they cost more width than they were worth. `PanelView.limitsFooter` is a new 30pt strip below the
  rows (`height` = header + 1 + list + 1 + footer = 290), carrying both windows WITH their reset
  times and the burn rate — which the bar never had room for. The bar's `rightText` is now just
  `countsText`, so with one agent working it prints nothing on the right: **519pt working / 449pt
  idle**, down from 591/525 and from ~727 at the symmetric worst. CollapsedView's `primaryQuota` /
  `primaryLimit` / `limitText` are deleted as dead.
  The footer's `window()` printed the CONSUMED figure bare ("5h 11%" next to a clock, which reads
  as readily as "11% left"); it now says **`5h 89% left 3h55m`**, matching the wording the bar used.
  Tint still keys on the consumed figure, so red still means nearly gone.
- **The bar now steps aside whenever nothing is running, on every display.** `autoHides` was
  gated on `safeAreaInsets.top == 0` (no-notch only), on the reasoning that a notch is dead pixels
  — but the bar outgrew the notch, so at rest it sat on the menu bar showing a stale number.
  Hover the notch to bring it back. Settings note updated to say so.
- **Percentages are rounded, not truncated**: `used_percentage` arrives fractional (28.999…) and
  `intValue` read 28 — a percent adrift from Claude's own display.
- **Per-chat tokens on every row**: `SessionStatus.totalTokens` (input+output from the session's own
  statusLine `context_window`, all 13 sessions carry it) rendered as a faint `309k` chip. Verified
  against the raw files. Selftest guards both, mutation-tested; the width-cap check now computes the
  widest printable line instead of pinning a magic number (it re-broke on exactly that).

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

## Autostart (2026-09-15)

The island was simply **not running after a reboot** — and nothing had ever been set up to start
it: no LaunchAgent, not in Login Items. `install.sh` now writes
`~/Library/LaunchAgents/sh.emergent.agentisland.plist` (RunAtLoad, Aqua-only, **no KeepAlive** —
Settings has a Quit and launchd must not undo it) and re-bootstraps it, so a fresh install or an
upgrade fixes the path too.

That means two starters — launchd at login and install.sh's own `open` — so the app grew a
**single-instance guard**: an advisory `flock` on `/tmp/agentisland.lock`, taken before
`NSApplication.shared`. A LaunchServices/`NSRunningApplication` check was tried first and does NOT
work: started by launchd or straight from a shell the process is not registered as an app yet, so
it sees nobody and both instances live (verified — two bars). The kernel drops the lock however the
process dies, so there is nothing to clean up.

Verified end to end: killed everything, `launchctl bootstrap` (what login does) → exactly one
instance, manifest refreshing, bar drawing. Second manual launch exits immediately. §48 pins all
of it. To undo: `launchctl bootout gui/$UID/sh.emergent.agentisland && rm ~/Library/LaunchAgents/sh.emergent.agentisland.plist`.

## The island was stealing clicks (2026-09-15)

With a browser fullscreen the top strip IS its tab bar, and those tabs could not be clicked:
**`HoverSensor` was a real `NSPanel` at `.statusBar` with `ignoresMouseEvents = false`**, so it
hit-tested and swallowed every click inside it. It was also **notch + 150 = 335pt wide**, a third
of the menu bar, so merely heading for something else up there opened the island.

- **Hover is a poll now, and that is the only design that works.** Three were tried:
  1. `NSPanel` + `NSTrackingArea` — sees every crossing, but a window with
     `ignoresMouseEvents = false` is handed the click by the WINDOW SERVER before anything
     underneath. Fullscreen browser ⇒ its tab bar is unclickable. Declining `hitTest` does NOT
     rescue it: that only reroutes *within* the window, so the click dies silently instead.
  2. Global `NSEvent` monitor — consumes nothing, but never saw the crossings (measured: 0 of 40
     synthetic moves, and no better by hand — this is what shipped briefly and did nothing).
  3. **No window, sample `NSEvent.mouseLocation` every 80ms.** Owns nothing, so it cannot swallow
     a click; sees a deliberate hover easily. The old "polling misses a 107ms crossing" objection
     is backwards here — missing a fast pass-through is exactly what stops the island opening on
     someone's way to the menu bar, and a real hover must outlast the 350ms dwell anyway.
- The strip has **two widths**, because it answers two questions. **Hidden**: `hotWidth` =
  notch + 80 (265pt here) — nothing is on screen to aim at, so it is a guess about intent; notch +
  150 opened on the way past, notch + 24 was so tight you had to hit the middle. **Visible**:
  `max(hotWidth, barWidth)` — the bar asks itself how wide it is drawing, because a strip narrower
  than the bar means hovering most of what you can see does nothing. `Island.hotRect` is the one
  definition, handed to the sensor as a closure so it re-reads it as the bar's width changes.
- **Hover can no longer be tested by driving the pointer.** Global `NSEvent` monitors do not
  observe synthetic `CGEvent` moves — measured: 0 of 40 posted events seen. The old tracking-area
  panel did see them, which is why the click-stealing sensor was testable and this is not. Assert
  the geometry in the suite and ask the user to confirm the feel.
- Hover intent **0.18s → 0.35s**, inside NN/g's 300–500ms band. Below it, the island opens on the
  way past to something else.
- The main panel now sets `ignoresMouseEvents = true` **at creation**, not just on the first poll
  tick: a 980x420 window accepting clicks across the top of the screen right after login is
  exactly the complaint, a second before the poll fixes it. Collapsed it always ignores events.

§49 pins all of it. Verified structurally: `CGWindowListCopyWindowInfo` shows AgentIsland owning
**one** on-screen window (the 980x420 panel), the 32pt sensor strip is gone.

## Working rules that bit us (obey them)

- **Never drive synthetic clicks/hover to verify.** It steals the pointer and raises apps on the
  machine the user is working on; doing it repeatedly in one turn locks them out (they asked for
  this explicitly). Everything routing-related is already verifiable with ZERO UI interaction:
  `/tmp/agentisland.rows.json` carries per-row host/pid/precise/caveat/target, `/tmp/agentisland.log`
  records the branch of every REAL click, and the suite already asserts "every live agent has
  somewhere to jump to" + "each interactive agent maps to a DISTINCT tab" over live sessions.
  `screencapture -x` is silent and safe — pixel-sample it rather than eyeballing. If a real click
  is genuinely required, do it ONCE at the end of the turn and say so first.

- Verify every fix against the MAIN FLOW (click a row → land on session), not just the
  symptom. That failure mode shipped 3 regressions in 2 days.
- Test text-matches must anchor on code, not comments ("CGEvent" matched a comment; use
  "CGEvent(").
- python .replace() on Swift: match FULL indentation or it hits substrings (mangled costChip
  once; build stayed green — ViewBuilder swallows garbage).
- Mutation-test new assertions (assert the mutation LANDED before trusting "caught").
- **Never edit selftest.py by slicing on string indices.** A needle that does not match (an
  escaping slip is enough — the file holds a literal `\n`, not a newline) makes `s[:a] + s[b:]`
  cut from the wrong offset: that silently deleted 39 sections / 1690 lines and still reported
  "all green", because the deleted checks no longer ran. Use exact-match anchored edits that fail
  loudly, and after ANY suite edit confirm the section and check counts
  (`grep -c '^print("' tests/selftest.py` = 67, ~584 checks) — not just the exit code.
- Restore mutated files immediately; a crashed harness once left the tree mutated.
- `defaults` bundle id: extract with PlistBuddy, never `tr -d '<string>'` (that deletes chars).
- Screenshots: verify by pixel-sampling, not eyeballs (opacity-on-content bug read as "gone"
  at lum 0.0 when an opaque black block still covered the tabs — fade the SHELL).
- cursor-task: refuses untrusted dirs; don't grant trust to cloned third-party repos. Named
  premium models now ALLOWED for important calls (user 2026-09-13, memory updated).
- User rules: no Claude subagents unless asked; comments ≤2 lines (hook enforces); branches
  feat/|fix/|change/; don't report token tallies.
