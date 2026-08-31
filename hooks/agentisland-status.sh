#!/bin/bash
# statusLine wrapper. Writes a per-session snapshot (context %, model, cost) plus a "latest"
# copy for account-wide quota, then runs the user's own statusline untouched.
PAYLOAD=$(cat)
DIR="${AGENTISLAND_STATUS_DIR:-/tmp/agentisland-status}"
mkdir -p "$DIR" 2>/dev/null
SID=$(printf '%s' "$PAYLOAD" | /usr/bin/sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
[ -n "$SID" ] && printf '%s' "$PAYLOAD" > "$DIR/$SID.json" 2>/dev/null
printf '%s' "$PAYLOAD" > /tmp/agentisland-status.json 2>/dev/null
[ -x "$HOME/.claude/statusline-command.sh" ] && printf '%s' "$PAYLOAD" | bash "$HOME/.claude/statusline-command.sh"
exit 0
