#!/bin/bash
# statusLine wrapper. Writes a per-session snapshot (context %, model, cost) plus a "latest"
# copy for account-wide quota, then runs the user's own statusline untouched.
# The payload carries the session id, the model and the running cost. /tmp is world-readable
# by default, so it is not somewhere to drop that at 0644.
umask 077
PAYLOAD=$(cat)
DIR="${AGENTISLAND_STATUS_DIR:-/tmp/agentisland-status}"
mkdir -p "$DIR" 2>/dev/null
# A directory or file someone else got to first is one they can read or redirect.
[ -L "$DIR" ] && exit 0
[ -O "$DIR" ] || exit 0
SID=$(printf '%s' "$PAYLOAD" | /usr/bin/sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
SID=$(printf '%s' "$SID" | /usr/bin/tr -cd 'A-Za-z0-9_-')   # a filename, never a path
[ -L "$DIR/$SID.json" ] || { [ -n "$SID" ] && printf '%s' "$PAYLOAD" > "$DIR/$SID.json" 2>/dev/null; }
LATEST="${AGENTISLAND_STATUS_LATEST:-/tmp/agentisland-status.json}"
if [ ! -L "$LATEST" ] && { [ ! -e "$LATEST" ] || [ -O "$LATEST" ]; }; then
    printf '%s' "$PAYLOAD" > "$LATEST" 2>/dev/null
fi
# Chain to whatever statusline was configured before us, saved verbatim at install time.
PREV="$HOME/.agentisland/prev-statusline"
if [ -s "$PREV" ]; then
    printf '%s' "$PAYLOAD" | bash -c "$(cat "$PREV")"
elif [ -x "$HOME/.claude/statusline-command.sh" ]; then
    printf '%s' "$PAYLOAD" | bash "$HOME/.claude/statusline-command.sh"
fi
exit 0
