#!/bin/bash
# Hooks block Claude Code, so this forks nothing and always exits 0.
SPOOL="${AGENTISLAND_SPOOL:-/tmp/agentisland-events.jsonl}"
IFS= read -r -d '' INPUT
[ -z "$INPUT" ] && exit 0
# $PPID is a shell builtin: the island walks up from it to find the agent process, which is
# the only way to bind a brand-new session (one started without --resume) to its terminal.
printf '{"ai_ppid":%s,"payload":%s}\n' "$PPID" "${INPUT//$'\n'/}" >> "$SPOOL" 2>/dev/null
exit 0
