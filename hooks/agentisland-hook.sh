#!/bin/bash
# Hooks block Claude Code, so this forks nothing and always exits 0.
SPOOL="${AGENTISLAND_SPOOL:-/tmp/agentisland-events.jsonl}"
IFS= read -r -d '' INPUT
[ -z "$INPUT" ] && exit 0
printf '%s\n' "${INPUT//$'\n'/}" >> "$SPOOL" 2>/dev/null
exit 0
