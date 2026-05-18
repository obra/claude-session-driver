#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CSD="$SCRIPT_DIR/../skills/driving-claude-code-sessions/scripts/csd"
WDIR=/tmp/claude-workers

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "  PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "  FAIL: $1 - $2"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

cleanup() {
  rm -f "$WDIR"/test-re-*.meta "$WDIR"/test-re-*.events.jsonl
}
trap cleanup EXIT
cleanup
mkdir -p "$WDIR"

SID="test-re-001"
echo '{"tmux_name":"test-re","session_id":"test-re-001","cwd":"/tmp"}' > "$WDIR/$SID.meta"
EF="$WDIR/$SID.events.jsonl"
cat > "$EF" <<'JSON'
{"ts":"t1","event":"session_start","cwd":"/tmp"}
{"ts":"t2","event":"user_prompt_submit"}
{"ts":"t3","event":"pre_tool_use","tool":"Bash","tool_input":{}}
{"ts":"t4","event":"stop"}
{"ts":"t5","event":"user_prompt_submit"}
{"ts":"t6","event":"stop"}
JSON

# default shows all events
OUTPUT=$(bash "$CSD" --worker test-re read-events)
COUNT=$(echo "$OUTPUT" | wc -l | tr -d ' ')
[ "$COUNT" = "6" ] && pass "default shows all 6 events" || fail "default count" "got $COUNT"

# --type stop filters
OUTPUT=$(bash "$CSD" --worker test-re read-events --type stop)
COUNT=$(echo "$OUTPUT" | wc -l | tr -d ' ')
[ "$COUNT" = "2" ] && pass "--type stop returns 2" || fail "type stop" "got $COUNT"

# --last 3
OUTPUT=$(bash "$CSD" --worker test-re read-events --last 3)
COUNT=$(echo "$OUTPUT" | wc -l | tr -d ' ')
[ "$COUNT" = "3" ] && pass "--last 3 returns 3" || fail "last 3" "got $COUNT"

# --type with --last
OUTPUT=$(bash "$CSD" --worker test-re read-events --type stop --last 1)
COUNT=$(echo "$OUTPUT" | wc -l | tr -d ' ')
[ "$COUNT" = "1" ] && pass "--type stop --last 1" || fail "type+last" "got $COUNT"

# invalid event type fails fast
EXIT_CODE=0
OUTPUT=$(bash "$CSD" --worker test-re read-events --type end_of_turn 2>&1) || EXIT_CODE=$?
[ "$EXIT_CODE" -ne 0 ] && pass "invalid --type exits non-zero" || fail "invalid type" "got 0"
echo "$OUTPUT" | grep -qi "not a known event" && pass "error names problem" || fail "msg" "$OUTPUT"

# missing event file errors
rm -f "$EF"
EXIT_CODE=0
bash "$CSD" --worker test-re read-events 2>/dev/null || EXIT_CODE=$?
[ "$EXIT_CODE" -ne 0 ] && pass "missing file exits non-zero" || fail "missing file" "exit 0"

TOTAL=$((PASS_COUNT + FAIL_COUNT))
echo ""
echo "Results: $PASS_COUNT/$TOTAL passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
