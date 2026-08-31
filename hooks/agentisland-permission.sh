#!/bin/bash
# PermissionRequest hook: ask the island, fall through to Claude's own prompt if it can't answer.
#
# Safety first — a hook that hangs freezes the session, so every failure path exits 0 with no
# output, which leaves Claude's normal permission prompt untouched.
SPOOL="${AGENTISLAND_SPOOL:-/tmp/agentisland-events.jsonl}"
DECISIONS="${AGENTISLAND_DECISIONS:-/tmp/agentisland-decisions}"
ALIVE="${AGENTISLAND_ALIVE:-/tmp/agentisland.alive}"
TIMEOUT_TENTHS="${AGENTISLAND_TIMEOUT_TENTHS:-200}"   # 20s

IFS= read -r -d '' INPUT
[ -z "$INPUT" ] && exit 0

# No island, or a stale heartbeat, means nobody can answer — don't intercept.
[ -f "$ALIVE" ] || exit 0
now=$(date +%s)
beat=$(stat -f %m "$ALIVE" 2>/dev/null || echo 0)
[ $((now - beat)) -gt 15 ] && exit 0

id="ap-$$-${now}"
mkdir -p "$DECISIONS" 2>/dev/null
printf '{"ap_request_id":"%s","payload":%s}\n' "$id" "${INPUT//$'\n'/}" >> "$SPOOL" 2>/dev/null

i=0
while [ "$i" -lt "$TIMEOUT_TENTHS" ]; do
    if [ -f "$DECISIONS/$id" ]; then
        decision=$(cat "$DECISIONS/$id" 2>/dev/null)
        rm -f "$DECISIONS/$id" 2>/dev/null
        case "$decision" in
            allow|deny)
                printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","permissionDecision":"%s","permissionDecisionReason":"AgentIsland: %s by user"}}\n' "$decision" "$decision"
                exit 0 ;;
            *) exit 0 ;;
        esac
    fi
    sleep 0.1
    i=$((i + 1))
done

# Timed out: withdraw silently so Claude prompts normally.
printf '' >> "$SPOOL" 2>/dev/null
exit 0
