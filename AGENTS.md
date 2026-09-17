# AgentIsland — working notes for any agent

A macOS notch app (Swift/SwiftUI, `LSUIElement`) that surfaces every running AI coding
agent. Full history and root causes: `docs/HANDOFF.md`. Read it before changing behaviour.

## Build: a plain `swift build` FAILS on this machine

Command Line Tools 27 ships a macOS 27 SDK in which SwiftUI's `@State` is a macro whose
plugin (`SwiftUIMacros`) exists only inside Xcode. CLT has Observation/Swift/Testing macros
and nothing for SwiftUI, so a clean build dies with ~90 identical errors. A warm `.build`
hides it until the first real recompile — do not conclude the tree is broken.

```sh
./install.sh                 # probes for a working SDK, builds release, installs, relaunches
# or, to build directly:
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift build
```

26.5 still declares `State` as a plain `@propertyWrapper struct`. Only `@State` is affected —
`@Published`, `@ObservedObject`, `@Environment`, `@FocusState` are ordinary property wrappers.
Shadowing the name `State` with a typealias does NOT work (the macro wins at every scope);
a *differently named* alias does. Never hard-code an SDK — `install.sh` probes, so full Xcode
silently takes over if it is ever installed.

## Test

```sh
python3 tests/selftest.py     # must end "0 failure(s) — all green"
```

Run it ONCE, at the end of a task. It reads live process state, so it is not free, and running
it after every edit is how you burn someone's afternoon.

Two sections are opt-in because they take over the machine. Never enable them by default:

```sh
AGENTISLAND_JUMP_E2E=1 python3 tests/selftest.py     # opens every agent's warp:// URL for real
AGENTISLAND_EXPLAIN_E2E=1 python3 tests/selftest.py  # makes a real billed ~12s headless call
python3 tests/terminals-e2e.py                       # opens real iTerm/Terminal windows
```

The jump section yanks the front tab once per live agent with a 2.2s settle — half a minute of
someone else's machine, per run. It was on by default and cost exactly that, many times a day.

The suite greps source TEXT as well as running the binary, so a rename can fail a check that
has nothing to do with your change — read the failure before "fixing" it. Several `tests/*.py`
are on-demand harnesses nothing references; they are NOT dead code.

## Rules that were learned the hard way

- Verify against the real flow end to end. A green text-match proves nothing on its own —
  mutation-test a new assertion by breaking the code and watching it fail.
- Never drive the GUI with synthetic clicks, keystrokes or cursor moves to "test" it. It
  steals the user's machine. Verify from `/tmp/agentisland.rows.json`, `/tmp/agentisland.log`
  and the suite instead.
- A refresh must spawn ZERO subprocesses; the suite enforces it. Do not add a shell-out to
  the discovery path.
- Never bulk-delete from `tests/selftest.py` with index slicing — deleted checks do not run,
  so the suite still says green. Edit by exact match.
- Keep comments to about two lines, and explain WHY, not what.
- Branches: `feat/` `fix/` `change/`.

## Layout

`Sources/AgentIsland/` — `AgentStore` (roster + refresh), `*Source.swift` (per-vendor
discovery), `HostTerminal` (jump), `Island`/`Views` (UI), `HoverSensor` (reveal strip).
Diagnostics land in `/tmp/agentisland.log`; the row manifest in `/tmp/agentisland.rows.json`.
