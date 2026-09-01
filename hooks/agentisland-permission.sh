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
# A plan takes longer to read than a shell command; give the reviewer a real window.
case "$INPUT" in *'"tool_name":"ExitPlanMode"'*)
    [ -z "$AGENTISLAND_TIMEOUT_TENTHS" ] && TIMEOUT_TENTHS=550 ;;   # a test's override still wins
esac

# No island, or a stale heartbeat, means nobody can answer — don't intercept.
[ -f "$ALIVE" ] || exit 0
now=$(date +%s)
beat=$(stat -f %m "$ALIVE" 2>/dev/null || echo 0)
[ $((now - beat)) -gt 15 ] && exit 0

id="ap-$$-${now}"
mkdir -p "$DECISIONS" 2>/dev/null
# A file here approves a shell command and /tmp is world-writable, so keep it owner-only.
chmod 700 "$DECISIONS" 2>/dev/null
printf '{"ap_request_id":"%s","payload":%s}\n' "$id" "${INPUT//$'\n'/}" >> "$SPOOL" 2>/dev/null

# The island writes $id.hold while the user is reading expanded context; a fresh hold extends
# the wait past the base timeout, up to a hard ceiling so a dead island can never park the
# session forever. Freshness is checked once a second to keep the loop free of subprocesses.
HARD_TENTHS="${AGENTISLAND_HOLD_HARD_TENTHS:-3000}"   # 5 min absolute ceiling
held=0
i=0
while [ "$i" -lt "$TIMEOUT_TENTHS" ] || { [ "$held" = 1 ] && [ "$i" -lt "$HARD_TENTHS" ]; }; do
    if [ $((i % 10)) -eq 0 ]; then
        held=0
        if [ -f "$DECISIONS/$id.hold" ]; then
            now2=$(date +%s)
            hm=$(stat -f %m "$DECISIONS/$id.hold" 2>/dev/null || echo 0)
            [ $((now2 - hm)) -lt 10 ] && held=1
        fi
    fi
    if [ -f "$DECISIONS/$id" ]; then
        rm -f "$DECISIONS/$id.hold" 2>/dev/null
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
rm -f "$DECISIONS/$id.hold" 2>/dev/null
printf '' >> "$SPOOL" 2>/dev/null
exit 0
