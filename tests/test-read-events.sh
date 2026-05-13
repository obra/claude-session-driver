#!/bin/bash
set -euo pipefail

# Test suite for read-events.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
READ_EVENTS="$SCRIPT_DIR/../skills/driving-claude-code-sessions/scripts/read-events.sh"
EVENT_DIR="/tmp/claude-workers"

PASS_COUNT=0
FAIL_COUNT=0

cleanup() {
  rm -f "$EVENT_DIR"/test-read-*.events.jsonl
}
trap cleanup EXIT

pass() {
  echo "  PASS: $1"
  PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
  echo "  FAIL: $1 - $2"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

setup() {
  cleanup
  mkdir -p "$EVENT_DIR"
}

# Shared test data: 5 events with 2 stops
create_test_file() {
  local session_id="$1"
  local event_file="$EVENT_DIR/${session_id}.events.jsonl"
  cat > "$event_file" <<'EVENTS'
{"ts":"2026-01-01T00:00:00Z","event":"session_start","cwd":"/tmp"}
{"ts":"2026-01-01T00:00:05Z","event":"user_prompt_submit"}
{"ts":"2026-01-01T00:00:10Z","event":"stop"}
{"ts":"2026-01-01T00:00:15Z","event":"user_prompt_submit"}
{"ts":"2026-01-01T00:00:20Z","event":"stop"}
EVENTS
}

# --- Test 1: Default shows all events ---
echo "Test 1: Default shows all events"
setup
SESSION_ID="test-read-001"
create_test_file "$SESSION_ID"

OUTPUT=$(bash "$READ_EVENTS" "$SESSION_ID")
LINE_COUNT=$(echo "$OUTPUT" | wc -l | tr -d ' ')

if [ "$LINE_COUNT" = "5" ]; then
  pass "default outputs all 5 events"
else
  fail "line count" "expected 5, got $LINE_COUNT"
fi

# Verify first and last lines are correct events
FIRST_EVENT=$(echo "$OUTPUT" | head -1 | jq -r '.event')
LAST_EVENT=$(echo "$OUTPUT" | tail -1 | jq -r '.event')

if [ "$FIRST_EVENT" = "session_start" ]; then
  pass "first event is session_start"
else
  fail "first event" "expected 'session_start', got '$FIRST_EVENT'"
fi

if [ "$LAST_EVENT" = "stop" ]; then
  pass "last event is stop"
else
  fail "last event" "expected 'stop', got '$LAST_EVENT'"
fi

# --- Test 2: --type filters to matching events ---
echo "Test 2: --type stop filters to only stop events"
setup
SESSION_ID="test-read-002"
create_test_file "$SESSION_ID"

OUTPUT=$(bash "$READ_EVENTS" "$SESSION_ID" --type stop)
LINE_COUNT=$(echo "$OUTPUT" | wc -l | tr -d ' ')

if [ "$LINE_COUNT" = "2" ]; then
  pass "--type stop returns 2 events"
else
  fail "filtered count" "expected 2, got $LINE_COUNT"
fi

# Verify both lines are stop events
ALL_STOP=true
while IFS= read -r line; do
  EVENT_VAL=$(echo "$line" | jq -r '.event')
  if [ "$EVENT_VAL" != "stop" ]; then
    ALL_STOP=false
    break
  fi
done <<< "$OUTPUT"

if [ "$ALL_STOP" = true ]; then
  pass "all filtered lines are stop events"
else
  fail "filter correctness" "found non-stop event in filtered output"
fi

# --- Test 3: --last N shows last N events ---
echo "Test 3: --last 2 shows last 2 events"
setup
SESSION_ID="test-read-003"
create_test_file "$SESSION_ID"

OUTPUT=$(bash "$READ_EVENTS" "$SESSION_ID" --last 2)
LINE_COUNT=$(echo "$OUTPUT" | wc -l | tr -d ' ')

if [ "$LINE_COUNT" = "2" ]; then
  pass "--last 2 returns 2 events"
else
  fail "last count" "expected 2, got $LINE_COUNT"
fi

# Verify they're the last 2 events from the file
FIRST_EVENT=$(echo "$OUTPUT" | head -1 | jq -r '.event')
LAST_EVENT=$(echo "$OUTPUT" | tail -1 | jq -r '.event')

if [ "$FIRST_EVENT" = "user_prompt_submit" ] && [ "$LAST_EVENT" = "stop" ]; then
  pass "last 2 events are user_prompt_submit and stop"
else
  fail "last 2 content" "expected 'user_prompt_submit' and 'stop', got '$FIRST_EVENT' and '$LAST_EVENT'"
fi

# --- Test 4: Missing file returns error ---
echo "Test 4: Missing file returns error (exit 1)"
setup
SESSION_ID="test-read-nonexistent"

OUTPUT=$(bash "$READ_EVENTS" "$SESSION_ID" 2>&1) && EXIT_CODE=0 || EXIT_CODE=$?

if [ "$EXIT_CODE" -eq 1 ]; then
  pass "exits 1 for missing file"
else
  fail "exit code" "expected 1, got $EXIT_CODE"
fi

if echo "$OUTPUT" | grep -qi "error"; then
  pass "error message mentions error"
else
  fail "error message" "expected error message, got '$OUTPUT'"
fi

# --- Test 5: --type and --last combined ---
echo "Test 5: --type stop --last 1 returns only the last stop event"
setup
SESSION_ID="test-read-005"
create_test_file "$SESSION_ID"

OUTPUT=$(bash "$READ_EVENTS" "$SESSION_ID" --type stop --last 1)
LINE_COUNT=$(echo "$OUTPUT" | wc -l | tr -d ' ')

if [ "$LINE_COUNT" = "1" ]; then
  pass "combined flags return 1 event"
else
  fail "combined count" "expected 1, got $LINE_COUNT"
fi

# Should be the second stop event (ts 00:00:20), not the first (ts 00:00:10)
TS_VAL=$(echo "$OUTPUT" | jq -r '.ts')
EVENT_VAL=$(echo "$OUTPUT" | jq -r '.event')

if [ "$EVENT_VAL" = "stop" ]; then
  pass "combined result is a stop event"
else
  fail "combined event" "expected 'stop', got '$EVENT_VAL'"
fi

if [ "$TS_VAL" = "2026-01-01T00:00:20Z" ]; then
  pass "combined result is the last stop event (ts=00:00:20Z)"
else
  fail "combined timestamp" "expected '2026-01-01T00:00:20Z', got '$TS_VAL'"
fi

# --- Summary ---
echo ""
TOTAL=$((PASS_COUNT + FAIL_COUNT))
echo "Results: $PASS_COUNT/$TOTAL passed, $FAIL_COUNT failed"

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
