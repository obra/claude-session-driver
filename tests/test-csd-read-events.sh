#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CSD="$SCRIPT_DIR/../skills/driving-claude-code-sessions/scripts/csd"
WDIR=/tmp/csd-workers

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "  PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "  FAIL: $1 - $2"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

cleanup() {
  rm -f "$WDIR"/test-re-*.meta "$WDIR"/test-re-*.events.jsonl
  rm -f /tmp/test-csd-follow-out.$$
  # Kill any leftover background follow processes from a failed test
  jobs -p 2>/dev/null | xargs -r kill 2>/dev/null || true
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

# --- --follow streams new events as they appear ---
# Use a second synthetic worker so the previous tests (which delete the file)
# don't race with this one.
SID2="test-re-002"
echo '{"tmux_name":"test-re-follow","session_id":"test-re-002","cwd":"/tmp"}' > "$WDIR/$SID2.meta"
EF2="$WDIR/$SID2.events.jsonl"
echo '{"ts":"t1","event":"session_start","cwd":"/tmp"}' > "$EF2"

FOLLOW_OUT=/tmp/test-csd-follow-out.$$
# Start follow in the background. It uses tail -f, so it will keep running
# until we kill it.
bash "$CSD" --worker test-re-follow read-events --follow > "$FOLLOW_OUT" 2>/dev/null &
FOLLOW_PID=$!

# Give tail -f a moment to attach to the file, then append a new event.
sleep 0.5
echo '{"ts":"t2","event":"stop"}' >> "$EF2"

# Give tail -f a moment to surface the new line.
sleep 0.5
kill "$FOLLOW_PID" 2>/dev/null || true
wait "$FOLLOW_PID" 2>/dev/null || true

# The follow output should contain both the pre-existing session_start (since
# tail -f reads the tail of the file at startup) and the newly-appended stop.
if grep -q '"event":"session_start"' "$FOLLOW_OUT"; then
  pass "--follow surfaces pre-existing events"
else
  fail "follow pre-existing" "expected session_start in: $(cat "$FOLLOW_OUT")"
fi
if grep -q '"event":"stop"' "$FOLLOW_OUT"; then
  pass "--follow surfaces newly-appended events"
else
  fail "follow append" "expected stop in: $(cat "$FOLLOW_OUT")"
fi

# --follow + --type filter combined
FOLLOW_OUT2=/tmp/test-csd-follow-out2.$$
bash "$CSD" --worker test-re-follow read-events --follow --type stop > "$FOLLOW_OUT2" 2>/dev/null &
FOLLOW_PID2=$!
sleep 0.5
echo '{"ts":"t3","event":"user_prompt_submit"}' >> "$EF2"
echo '{"ts":"t4","event":"stop"}' >> "$EF2"
sleep 0.5
kill "$FOLLOW_PID2" 2>/dev/null || true
wait "$FOLLOW_PID2" 2>/dev/null || true

# With --type stop, the user_prompt_submit line must not appear.
if grep -q '"event":"user_prompt_submit"' "$FOLLOW_OUT2"; then
  fail "follow type filter" "user_prompt_submit leaked into --type stop follow: $(cat "$FOLLOW_OUT2")"
else
  pass "--follow --type filters out non-matching events"
fi
if grep -q '"event":"stop"' "$FOLLOW_OUT2"; then
  pass "--follow --type still surfaces matching events"
else
  fail "follow type stop" "expected stop in: $(cat "$FOLLOW_OUT2")"
fi
rm -f "$FOLLOW_OUT" "$FOLLOW_OUT2"

# missing event file errors
rm -f "$EF"
EXIT_CODE=0
bash "$CSD" --worker test-re read-events 2>/dev/null || EXIT_CODE=$?
[ "$EXIT_CODE" -ne 0 ] && pass "missing file exits non-zero" || fail "missing file" "exit 0"

TOTAL=$((PASS_COUNT + FAIL_COUNT))
echo ""
echo "Results: $PASS_COUNT/$TOTAL passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
