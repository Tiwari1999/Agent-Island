#!/bin/bash
# Stand-in for an agent process, and it has to match a real one in two ways.
#
# It must be a CHILD of the tab's shell, because Warp exports its per-session handle from the
# shell rc file: everything the shell launches carries it. A real agent sits in that position.
#
# It must also be a NON-Apple binary. macOS hides the environment of platform binaries from `ps`,
# which is exactly where the handle is read from -- /bin/sleep reports zero environment variables
# while a Homebrew python reports sixty-six. Every real agent (claude, codex, cursor-agent) is a
# third-party binary, so this matches them; using /bin/sleep would measure a limitation of the
# stand-in rather than of the app.
#
# It writes its own pid rather than the caller using $!, which zsh expands as history on an
# interactive command line and silently kills the whole command.
echo "$1 $$ ${WARP_FOCUS_URL:-none}" >> "$2"
PY=/opt/homebrew/bin/python3
[ -x "$PY" ] || PY=$(command -v python3)
exec "$PY" -c 'import time; time.sleep(36000)'
