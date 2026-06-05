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
  rm -f "$WDIR"/test-readers-*.meta "$WDIR"/test-readers-*.events.jsonl
}
trap cleanup EXIT
cleanup
mkdir -p "$WDIR"

SESSION_ID="test-readers-abc"
TMUX_NAME="test-readers"
echo "{\"tmux_name\":\"$TMUX_NAME\",\"session_id\":\"$SESSION_ID\",\"cwd\":\"/tmp\",\"started_at\":\"2025-01-01T00:00:00Z\"}" > "$WDIR/$SESSION_ID.meta"

# --- session-id by tmux name ---
echo "Test 1: session-id by tmux name"
OUTPUT=$(bash "$CSD" --worker "$TMUX_NAME" session-id)
if [ "$OUTPUT" = "$SESSION_ID" ]; then
  pass "returns session_id"
else
  fail "session-id" "expected $SESSION_ID, got $OUTPUT"
fi

# --- session-id by session id passthrough ---
echo "Test 2: session-id by session_id"
OUTPUT=$(bash "$CSD" --worker "$SESSION_ID" session-id)
if [ "$OUTPUT" = "$SESSION_ID" ]; then
  pass "session_id passthrough"
else
  fail "passthrough" "expected $SESSION_ID, got $OUTPUT"
fi

# --- events-file path ---
echo "Test 3: events-file"
OUTPUT=$(bash "$CSD" --worker "$TMUX_NAME" events-file)
EXPECTED="/tmp/csd-workers/$SESSION_ID.events.jsonl"
if [ "$OUTPUT" = "$EXPECTED" ]; then
  pass "events-file path"
else
  fail "events-file" "expected $EXPECTED, got $OUTPUT"
fi

# --- unknown worker fails ---
echo "Test 4: unknown worker fails"
EXIT_CODE=0
OUTPUT=$(bash "$CSD" --worker no-such-worker session-id 2>&1) || EXIT_CODE=$?
if [ "$EXIT_CODE" -ne 0 ]; then
  pass "unknown worker exits non-zero"
else
  fail "unknown worker" "expected non-zero exit"
fi

TOTAL=$((PASS_COUNT + FAIL_COUNT))
echo ""
echo "Results: $PASS_COUNT/$TOTAL passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
