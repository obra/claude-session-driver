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
  tmux kill-session -t test-status-alive 2>/dev/null || true
  rm -f "$WDIR"/test-status-*.meta "$WDIR"/test-status-*.events.jsonl
}
trap cleanup EXIT
cleanup
mkdir -p "$WDIR"

# --- gone: tmux session does not exist ---
echo '{"tmux_name":"test-status-gone","session_id":"test-status-001","cwd":"/tmp"}' > "$WDIR/test-status-001.meta"
echo '{"event":"stop"}' > "$WDIR/test-status-001.events.jsonl"
OUTPUT=$(bash "$CSD" --worker test-status-gone status)
[ "$OUTPUT" = "gone" ] && pass "gone when tmux missing" || fail "gone" "got '$OUTPUT'"

# --- live tmux but various last events ---
tmux new-session -d -s test-status-alive -c /tmp 'sleep 60'
echo '{"tmux_name":"test-status-alive","session_id":"test-status-002","cwd":"/tmp"}' > "$WDIR/test-status-002.meta"

# unknown: no events file
rm -f "$WDIR/test-status-002.events.jsonl"
OUTPUT=$(bash "$CSD" --worker test-status-alive status)
[ "$OUTPUT" = "unknown" ] && pass "unknown when no events" || fail "unknown" "got '$OUTPUT'"

# idle: last event = session_start
echo '{"event":"session_start","cwd":"/tmp"}' > "$WDIR/test-status-002.events.jsonl"
OUTPUT=$(bash "$CSD" --worker test-status-alive status)
[ "$OUTPUT" = "idle" ] && pass "idle on session_start" || fail "idle/session_start" "got '$OUTPUT'"

# idle: last event = stop
echo '{"event":"stop"}' >> "$WDIR/test-status-002.events.jsonl"
OUTPUT=$(bash "$CSD" --worker test-status-alive status)
[ "$OUTPUT" = "idle" ] && pass "idle on stop" || fail "idle/stop" "got '$OUTPUT'"

# working: last event = user_prompt_submit
echo '{"event":"user_prompt_submit"}' >> "$WDIR/test-status-002.events.jsonl"
OUTPUT=$(bash "$CSD" --worker test-status-alive status)
[ "$OUTPUT" = "working" ] && pass "working on user_prompt_submit" || fail "working/ups" "got '$OUTPUT'"

# working: last event = pre_tool_use
echo '{"event":"pre_tool_use","tool":"Bash","tool_input":{}}' >> "$WDIR/test-status-002.events.jsonl"
OUTPUT=$(bash "$CSD" --worker test-status-alive status)
[ "$OUTPUT" = "working" ] && pass "working on pre_tool_use" || fail "working/ptu" "got '$OUTPUT'"

# terminated: last event = session_end
echo '{"event":"session_end"}' >> "$WDIR/test-status-002.events.jsonl"
OUTPUT=$(bash "$CSD" --worker test-status-alive status)
[ "$OUTPUT" = "terminated" ] && pass "terminated on session_end" || fail "terminated" "got '$OUTPUT'"

TOTAL=$((PASS_COUNT + FAIL_COUNT))
echo ""
echo "Results: $PASS_COUNT/$TOTAL passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
