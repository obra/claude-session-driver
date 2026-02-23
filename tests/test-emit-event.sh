#!/bin/bash
set -euo pipefail

# Test suite for emit-event.sh hook script

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EMIT_EVENT="$SCRIPT_DIR/../hooks/emit-event.sh"
EVENT_DIR="/tmp/claude-workers"

PASS_COUNT=0
FAIL_COUNT=0

cleanup() {
  rm -f "$EVENT_DIR"/test-*.events.jsonl
  rm -f "$EVENT_DIR"/test-*.meta
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

# Clean slate before each test
setup() {
  cleanup
}

# Create a .meta file to simulate a managed worker session
make_worker() {
  local sid="$1"
  mkdir -p "$EVENT_DIR"
  echo '{"tmux_name":"test","session_id":"'"$sid"'"}' > "$EVENT_DIR/${sid}.meta"
}

# --- Test: Non-worker sessions are silently skipped ---
echo "Test: Non-worker sessions are silently skipped"
setup
SESSION_ID="test-session-000"
EVENT_FILE="$EVENT_DIR/${SESSION_ID}.events.jsonl"

# No make_worker — this is a normal interactive session
echo '{"session_id":"test-session-000","hook_event_name":"SessionStart","cwd":"/home/user/project"}' \
  | bash "$EMIT_EVENT" > /dev/null

if [ ! -f "$EVENT_FILE" ]; then
  pass "non-worker session does not create event file"
else
  fail "non-worker skip" "event file should not exist"
fi

# --- Test: SessionStart creates file with correct JSONL ---
echo "Test: SessionStart creates file with correct JSONL"
setup
SESSION_ID="test-session-001"
make_worker "$SESSION_ID"
EVENT_FILE="$EVENT_DIR/${SESSION_ID}.events.jsonl"

echo '{"session_id":"test-session-001","hook_event_name":"SessionStart","cwd":"/home/user/project"}' \
  | bash "$EMIT_EVENT" > /dev/null

if [ ! -f "$EVENT_FILE" ]; then
  fail "file exists" "event file was not created"
else
  LINE=$(head -1 "$EVENT_FILE")
  EVENT_VAL=$(echo "$LINE" | jq -r '.event')
  CWD_VAL=$(echo "$LINE" | jq -r '.cwd')
  TS_VAL=$(echo "$LINE" | jq -r '.ts')

  if [ "$EVENT_VAL" = "session_start" ]; then
    pass "event field is session_start"
  else
    fail "event field" "expected 'session_start', got '$EVENT_VAL'"
  fi

  if [ "$CWD_VAL" = "/home/user/project" ]; then
    pass "cwd field is correct"
  else
    fail "cwd field" "expected '/home/user/project', got '$CWD_VAL'"
  fi

  if echo "$TS_VAL" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'; then
    pass "ts field is ISO 8601 UTC"
  else
    fail "ts field format" "expected ISO 8601 UTC, got '$TS_VAL'"
  fi

  # Verify it's valid JSON with exactly the expected keys
  KEY_COUNT=$(echo "$LINE" | jq 'keys | length')
  if [ "$KEY_COUNT" = "3" ]; then
    pass "session_start event has exactly 3 keys (ts, event, cwd)"
  else
    fail "key count" "expected 3 keys, got $KEY_COUNT"
  fi
fi

# --- Test: Stop outputs approve decision AND writes event ---
echo "Test: Stop outputs approve decision and writes event"
setup
SESSION_ID="test-session-002"
make_worker "$SESSION_ID"
EVENT_FILE="$EVENT_DIR/${SESSION_ID}.events.jsonl"

STDOUT=$(echo '{"session_id":"test-session-002","hook_event_name":"Stop"}' \
  | bash "$EMIT_EVENT")

# Check stdout contains approve decision
DECISION=$(echo "$STDOUT" | jq -r '.decision')
if [ "$DECISION" = "approve" ]; then
  pass "Stop outputs {\"decision\":\"approve\"}"
else
  fail "Stop stdout" "expected decision 'approve', got '$DECISION'"
fi

# Check event was also written to file
if [ ! -f "$EVENT_FILE" ]; then
  fail "Stop file exists" "event file was not created"
else
  LINE=$(head -1 "$EVENT_FILE")
  EVENT_VAL=$(echo "$LINE" | jq -r '.event')
  if [ "$EVENT_VAL" = "stop" ]; then
    pass "Stop event written to file as 'stop'"
  else
    fail "Stop event in file" "expected 'stop', got '$EVENT_VAL'"
  fi

  # Stop event should NOT have cwd
  CWD_VAL=$(echo "$LINE" | jq -r '.cwd // "ABSENT"')
  if [ "$CWD_VAL" = "ABSENT" ]; then
    pass "Stop event has no cwd field"
  else
    fail "Stop cwd" "expected no cwd field, got '$CWD_VAL'"
  fi
fi

# --- Test: UserPromptSubmit writes correctly ---
echo "Test: UserPromptSubmit writes correctly"
setup
SESSION_ID="test-session-003"
make_worker "$SESSION_ID"
EVENT_FILE="$EVENT_DIR/${SESSION_ID}.events.jsonl"

echo '{"session_id":"test-session-003","hook_event_name":"UserPromptSubmit"}' \
  | bash "$EMIT_EVENT" > /dev/null

if [ ! -f "$EVENT_FILE" ]; then
  fail "UserPromptSubmit file exists" "event file was not created"
else
  LINE=$(head -1 "$EVENT_FILE")
  EVENT_VAL=$(echo "$LINE" | jq -r '.event')
  if [ "$EVENT_VAL" = "user_prompt_submit" ]; then
    pass "UserPromptSubmit maps to user_prompt_submit"
  else
    fail "UserPromptSubmit event" "expected 'user_prompt_submit', got '$EVENT_VAL'"
  fi
fi

# --- Test: SessionEnd writes correctly ---
echo "Test: SessionEnd writes correctly"
setup
SESSION_ID="test-session-004"
make_worker "$SESSION_ID"
EVENT_FILE="$EVENT_DIR/${SESSION_ID}.events.jsonl"

echo '{"session_id":"test-session-004","hook_event_name":"SessionEnd"}' \
  | bash "$EMIT_EVENT" > /dev/null

if [ ! -f "$EVENT_FILE" ]; then
  fail "SessionEnd file exists" "event file was not created"
else
  LINE=$(head -1 "$EVENT_FILE")
  EVENT_VAL=$(echo "$LINE" | jq -r '.event')
  if [ "$EVENT_VAL" = "session_end" ]; then
    pass "SessionEnd maps to session_end"
  else
    fail "SessionEnd event" "expected 'session_end', got '$EVENT_VAL'"
  fi
fi

# --- Test: Multiple events append to same file ---
echo "Test: Multiple events append to same file"
setup
SESSION_ID="test-session-005"
make_worker "$SESSION_ID"
EVENT_FILE="$EVENT_DIR/${SESSION_ID}.events.jsonl"

echo '{"session_id":"test-session-005","hook_event_name":"SessionStart","cwd":"/tmp"}' \
  | bash "$EMIT_EVENT" > /dev/null
echo '{"session_id":"test-session-005","hook_event_name":"UserPromptSubmit"}' \
  | bash "$EMIT_EVENT" > /dev/null
echo '{"session_id":"test-session-005","hook_event_name":"SessionEnd"}' \
  | bash "$EMIT_EVENT" > /dev/null

if [ ! -f "$EVENT_FILE" ]; then
  fail "multi-event file exists" "event file was not created"
else
  LINE_COUNT=$(wc -l < "$EVENT_FILE" | tr -d ' ')
  if [ "$LINE_COUNT" = "3" ]; then
    pass "3 events produce 3 lines"
  else
    fail "line count" "expected 3 lines, got $LINE_COUNT"
  fi

  # Verify each line is valid JSON with correct event name
  EVENT_1=$(sed -n '1p' "$EVENT_FILE" | jq -r '.event')
  EVENT_2=$(sed -n '2p' "$EVENT_FILE" | jq -r '.event')
  EVENT_3=$(sed -n '3p' "$EVENT_FILE" | jq -r '.event')

  if [ "$EVENT_1" = "session_start" ] && [ "$EVENT_2" = "user_prompt_submit" ] && [ "$EVENT_3" = "session_end" ]; then
    pass "events are in correct order with correct names"
  else
    fail "event order" "got '$EVENT_1', '$EVENT_2', '$EVENT_3'"
  fi
fi

# --- Test: Hook event names map to snake_case ---
echo "Test: Hook event names map to snake_case"

check_mapping() {
  local hook_name="$1"
  local expected="$2"
  local session_id="test-session-006-${hook_name}"
  local event_file="$EVENT_DIR/${session_id}.events.jsonl"
  cleanup
  make_worker "$session_id"

  local input="{\"session_id\":\"${session_id}\",\"hook_event_name\":\"${hook_name}\"}"
  if [ "$hook_name" = "SessionStart" ]; then
    input="{\"session_id\":\"${session_id}\",\"hook_event_name\":\"${hook_name}\",\"cwd\":\"/tmp\"}"
  fi

  echo "$input" | bash "$EMIT_EVENT" > /dev/null

  local actual
  actual=$(head -1 "$event_file" | jq -r '.event')

  if [ "$actual" = "$expected" ]; then
    pass "$hook_name -> $expected"
  else
    fail "$hook_name mapping" "expected '$expected', got '$actual'"
  fi
}

check_mapping "SessionStart"     "session_start"
check_mapping "Stop"             "stop"
check_mapping "UserPromptSubmit" "user_prompt_submit"
check_mapping "SessionEnd"       "session_end"

# --- Summary ---
echo ""
TOTAL=$((PASS_COUNT + FAIL_COUNT))
echo "Results: $PASS_COUNT/$TOTAL passed, $FAIL_COUNT failed"

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
