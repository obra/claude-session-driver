#!/bin/bash
set -euo pipefail

# Test suite for wait-for-event.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WAIT_FOR_EVENT="$SCRIPT_DIR/../skills/driving-claude-code-sessions/scripts/wait-for-event.sh"
EVENT_DIR="/tmp/claude-workers"

PASS_COUNT=0
FAIL_COUNT=0

cleanup() {
  rm -f "$EVENT_DIR"/test-wait-*.events.jsonl
  # Kill any lingering background jobs from tests
  jobs -p 2>/dev/null | xargs kill 2>/dev/null || true
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

# --- Test 1: Finds event already present in file ---
echo "Test 1: Finds event already present in file"
setup
SESSION_ID="test-wait-001"
EVENT_FILE="$EVENT_DIR/${SESSION_ID}.events.jsonl"

echo '{"ts":"2025-01-01T00:00:00Z","event":"session_start","cwd":"/tmp"}' > "$EVENT_FILE"

OUTPUT=$(bash "$WAIT_FOR_EVENT" "$SESSION_ID" "session_start" 5)
EXIT_CODE=$?

if [ "$EXIT_CODE" -eq 0 ]; then
  pass "exits 0 when event already present"
else
  fail "exit code" "expected 0, got $EXIT_CODE"
fi

EVENT_VAL=$(echo "$OUTPUT" | jq -r '.event')
if [ "$EVENT_VAL" = "session_start" ]; then
  pass "outputs the matching event JSON"
else
  fail "event output" "expected 'session_start', got '$EVENT_VAL'"
fi

# --- Test 2: Finds event appended after start ---
echo "Test 2: Finds event appended after start"
setup
SESSION_ID="test-wait-002"
EVENT_FILE="$EVENT_DIR/${SESSION_ID}.events.jsonl"

# Create file with a non-matching event so it exists
echo '{"ts":"2025-01-01T00:00:00Z","event":"session_start","cwd":"/tmp"}' > "$EVENT_FILE"

# Append the target event after 1 second in background
(sleep 1 && echo '{"ts":"2025-01-01T00:00:01Z","event":"stop"}' >> "$EVENT_FILE") &

OUTPUT=$(bash "$WAIT_FOR_EVENT" "$SESSION_ID" "stop" 10)
EXIT_CODE=$?

if [ "$EXIT_CODE" -eq 0 ]; then
  pass "exits 0 when event appended later"
else
  fail "exit code" "expected 0, got $EXIT_CODE"
fi

EVENT_VAL=$(echo "$OUTPUT" | jq -r '.event')
if [ "$EVENT_VAL" = "stop" ]; then
  pass "outputs the matching event JSON"
else
  fail "event output" "expected 'stop', got '$EVENT_VAL'"
fi

# --- Test 3: Times out when event never appears ---
echo "Test 3: Times out when event never appears"
setup
SESSION_ID="test-wait-003"
EVENT_FILE="$EVENT_DIR/${SESSION_ID}.events.jsonl"

# Only a session_start present; waiting for a valid event that never arrives.
echo '{"ts":"2025-01-01T00:00:00Z","event":"session_start","cwd":"/tmp"}' > "$EVENT_FILE"

EXIT_CODE=0
OUTPUT=$(bash "$WAIT_FOR_EVENT" "$SESSION_ID" "stop" 2 2>/dev/null) || EXIT_CODE=$?

if [ "${EXIT_CODE:-0}" -eq 1 ]; then
  pass "exits 1 on timeout"
else
  fail "exit code" "expected 1, got ${EXIT_CODE:-0}"
fi

if [ -z "$OUTPUT" ]; then
  pass "no stdout output on timeout"
else
  fail "stdout on timeout" "expected empty, got '$OUTPUT'"
fi

# --- Test 3b: Rejects unknown event names fast ---
echo "Test 3b: Rejects unknown event names fast"
setup
SESSION_ID="test-wait-003b"
EVENT_FILE="$EVENT_DIR/${SESSION_ID}.events.jsonl"
echo '{"ts":"2025-01-01T00:00:00Z","event":"session_start","cwd":"/tmp"}' > "$EVENT_FILE"

START=$SECONDS
EXIT_CODE=0
STDERR_OUTPUT=$(bash "$WAIT_FOR_EVENT" "$SESSION_ID" "end_of_turn" 60 2>&1 >/dev/null) || EXIT_CODE=$?
ELAPSED=$((SECONDS - START))

if [ "${EXIT_CODE:-0}" -ne 0 ]; then
  pass "exits non-zero on invalid event name"
else
  fail "exit code" "expected non-zero, got 0"
fi

if [ "$ELAPSED" -lt 5 ]; then
  pass "fails fast (under 5s, did not wait the 60s timeout)"
else
  fail "elapsed" "expected <5s, took ${ELAPSED}s"
fi

if echo "$STDERR_OUTPUT" | grep -q "not a known event type"; then
  pass "stderr names the problem and lists valid events"
else
  fail "stderr message" "expected guidance about valid events, got '$STDERR_OUTPUT'"
fi

# --- Test 4: Ignores non-matching events ---
echo "Test 4: Ignores non-matching events"
setup
SESSION_ID="test-wait-004"
EVENT_FILE="$EVENT_DIR/${SESSION_ID}.events.jsonl"

# Start with wrong event
echo '{"ts":"2025-01-01T00:00:00Z","event":"session_start","cwd":"/tmp"}' > "$EVENT_FILE"

# Append another wrong event after 0.5s, then the right one after 1.5s
(sleep 0.5 && echo '{"ts":"2025-01-01T00:00:01Z","event":"user_prompt_submit"}' >> "$EVENT_FILE") &
(sleep 1.5 && echo '{"ts":"2025-01-01T00:00:02Z","event":"session_end"}' >> "$EVENT_FILE") &

OUTPUT=$(bash "$WAIT_FOR_EVENT" "$SESSION_ID" "session_end" 10)
EXIT_CODE=$?

if [ "$EXIT_CODE" -eq 0 ]; then
  pass "exits 0 when matching event found"
else
  fail "exit code" "expected 0, got $EXIT_CODE"
fi

EVENT_VAL=$(echo "$OUTPUT" | jq -r '.event')
if [ "$EVENT_VAL" = "session_end" ]; then
  pass "outputs only the matching event"
else
  fail "event output" "expected 'session_end', got '$EVENT_VAL'"
fi

# --- Test 5: Works when file doesn't exist yet ---
echo "Test 5: Works when file doesn't exist yet"
setup
SESSION_ID="test-wait-005"
EVENT_FILE="$EVENT_DIR/${SESSION_ID}.events.jsonl"
# Meta file is required so the resolver in _lib.sh recognizes the session.
# In real flow, launch-worker.sh creates this before wait-for-event runs.
echo "{\"tmux_name\":\"test-wait-005\",\"session_id\":\"${SESSION_ID}\"}" > "$EVENT_DIR/${SESSION_ID}.meta"

# Events file does NOT exist. Create it with the target event after 1.5 seconds.
(sleep 1.5 && echo '{"ts":"2025-01-01T00:00:00Z","event":"stop"}' > "$EVENT_FILE") &

OUTPUT=$(bash "$WAIT_FOR_EVENT" "$SESSION_ID" "stop" 10)
EXIT_CODE=$?

if [ "$EXIT_CODE" -eq 0 ]; then
  pass "exits 0 when file created later"
else
  fail "exit code" "expected 0, got $EXIT_CODE"
fi

EVENT_VAL=$(echo "$OUTPUT" | jq -r '.event')
if [ "$EVENT_VAL" = "stop" ]; then
  pass "outputs the matching event from late-created file"
else
  fail "event output" "expected 'stop', got '$EVENT_VAL'"
fi

# --- Test 6: --after-line skips earlier events ---
echo "Test 6: --after-line skips earlier events"
setup
SESSION_ID="test-wait-006"
EVENT_FILE="$EVENT_DIR/${SESSION_ID}.events.jsonl"

# Write 3 events: session_start, stop, user_prompt_submit
echo '{"ts":"2025-01-01T00:00:00Z","event":"session_start","cwd":"/tmp"}' > "$EVENT_FILE"
echo '{"ts":"2025-01-01T00:00:05Z","event":"stop"}' >> "$EVENT_FILE"
echo '{"ts":"2025-01-01T00:00:10Z","event":"user_prompt_submit"}' >> "$EVENT_FILE"

# Without --after-line, should find the stop on line 2
OUTPUT=$(bash "$WAIT_FOR_EVENT" "$SESSION_ID" "stop" 5)
EXIT_CODE=$?
if [ "$EXIT_CODE" -eq 0 ]; then
  TS=$(echo "$OUTPUT" | jq -r '.ts')
  if [ "$TS" = "2025-01-01T00:00:05Z" ]; then
    pass "without --after-line, finds first stop (ts=00:00:05Z)"
  else
    fail "wrong stop event" "expected ts=00:00:05Z, got $TS"
  fi
else
  fail "exit code" "expected 0, got $EXIT_CODE"
fi

# With --after-line 2, should skip lines 1-2 and NOT find a stop (only user_prompt_submit on line 3)
OUTPUT=$(bash "$WAIT_FOR_EVENT" "$SESSION_ID" "stop" 2 --after-line 2 2>/dev/null) || EXIT_CODE=$?
if [ "${EXIT_CODE:-0}" -eq 1 ]; then
  pass "--after-line 2 skips the stop on line 2 and times out"
else
  fail "exit code" "expected 1 (timeout), got ${EXIT_CODE:-0}"
fi

# Now append a new stop event and try again with --after-line 3
echo '{"ts":"2025-01-01T00:00:20Z","event":"stop"}' >> "$EVENT_FILE"

OUTPUT=$(bash "$WAIT_FOR_EVENT" "$SESSION_ID" "stop" 5 --after-line 3)
EXIT_CODE=$?
if [ "$EXIT_CODE" -eq 0 ]; then
  TS=$(echo "$OUTPUT" | jq -r '.ts')
  if [ "$TS" = "2025-01-01T00:00:20Z" ]; then
    pass "--after-line 3 finds only the new stop (ts=00:00:20Z)"
  else
    fail "wrong stop event" "expected ts=00:00:20Z, got $TS"
  fi
else
  fail "exit code" "expected 0, got $EXIT_CODE"
fi

# --- Summary ---
echo ""
TOTAL=$((PASS_COUNT + FAIL_COUNT))
echo "Results: $PASS_COUNT/$TOTAL passed, $FAIL_COUNT failed"

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
