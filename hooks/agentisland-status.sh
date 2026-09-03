#!/bin/bash
# statusLine wrapper. Writes a per-session snapshot (context %, model, cost) plus a "latest"
# copy for account-wide quota, then runs the user's own statusline untouched.
PAYLOAD=$(cat)
DIR="${AGENTISLAND_STATUS_DIR:-/tmp/agentisland-status}"
mkdir -p "$DIR" 2>/dev/null
SID=$(printf '%s' "$PAYLOAD" | /usr/bin/sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
SID=$(printf '%s' "$SID" | /usr/bin/tr -cd 'A-Za-z0-9_-')   # a filename, never a path
[ -n "$SID" ] && printf '%s' "$PAYLOAD" > "$DIR/$SID.json" 2>/dev/null
printf '%s' "$PAYLOAD" > /tmp/agentisland-status.json 2>/dev/null
# Chain to whatever statusline was configured before us, saved verbatim at install time.
PREV="$HOME/.agentisland/prev-statusline"
if [ -s "$PREV" ]; then
    printf '%s' "$PAYLOAD" | bash -c "$(cat "$PREV")"
elif [ -x "$HOME/.claude/statusline-command.sh" ]; then
    printf '%s' "$PAYLOAD" | bash "$HOME/.claude/statusline-command.sh"
fi
exit 0
