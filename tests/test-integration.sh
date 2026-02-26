#!/bin/bash
# Integration test for the claude-session-driver plugin.
# Launches a real Claude Code worker session, sends a prompt, verifies events, and cleans up.
#
# Requirements: claude CLI, tmux, jq
# This test costs API credits (launches a real Claude session).
#
# Usage: bash test-integration.sh [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FAILURES=0
TESTS=0
SESSION_ID=""
TMUX_NAME="integration-test-$$"
WORKER_TMUX_NAME=""

DRY_RUN=false
if [ "${1:-}" = "--dry-run" ]; then
  DRY_RUN=true
fi

fail() {
  echo "FAIL: $1"
  FAILURES=$((FAILURES + 1))
}

pass() {
  echo "PASS: $1"
}

run_test() {
  TESTS=$((TESTS + 1))
}

cleanup() {
  TARGET_TMUX="${WORKER_TMUX_NAME:-$TMUX_NAME}"
  if [ -n "$SESSION_ID" ]; then
    bash "$PLUGIN_DIR/scripts/stop-worker.sh" "$TARGET_TMUX" "$SESSION_ID" 2>/dev/null || true
  fi
  # Belt and suspenders
  tmux kill-session -t "$TARGET_TMUX" 2>/dev/null || true
  if [ -n "$SESSION_ID" ]; then
    rm -f "/tmp/claude-workers/${SESSION_ID}.events.jsonl"
    rm -f "/tmp/claude-workers/${SESSION_ID}.meta"
  fi
}
trap cleanup EXIT

if [ "$DRY_RUN" = true ]; then
  echo "=== Dry Run: Checking prerequisites ==="

  run_test
  if command -v claude &>/dev/null; then
    pass "claude CLI available"
  else
    fail "claude CLI not found"
  fi

  run_test
  if command -v tmux &>/dev/null; then
    pass "tmux available"
  else
    fail "tmux not found"
  fi

  run_test
  if command -v jq &>/dev/null; then
    pass "jq available"
  else
    fail "jq not found"
  fi

  run_test
  if [ -f "$PLUGIN_DIR/.claude-plugin/plugin.json" ]; then
    pass "Plugin directory found at $PLUGIN_DIR"
  else
    fail "Plugin directory not found"
  fi

  run_test
  for script in launch-worker.sh send-prompt.sh wait-for-event.sh read-events.sh stop-worker.sh; do
    if [ ! -x "$PLUGIN_DIR/scripts/$script" ]; then
      fail "Script not executable: $script"
    fi
  done
  pass "All scripts are executable"

  run_test
  if [ -f "$PLUGIN_DIR/hooks/hooks.json" ] && [ -x "$PLUGIN_DIR/hooks/emit-event.sh" ]; then
    pass "Hooks configured"
  else
    fail "Hooks missing"
  fi

  echo ""
  echo "Dry run results: $((TESTS - FAILURES))/$TESTS passed"
  if [ "$FAILURES" -gt 0 ]; then
    exit 1
  fi
  echo "Ready for live test (run without --dry-run)"
  exit 0
fi

echo "=== Integration Test: Full Worker Lifecycle ==="
echo "Using tmux session name: $TMUX_NAME"
echo ""

# --- Test 1: Launch a worker ---
run_test
echo "Test 1: Launch worker..."
# Short approval timeout so hook-gated tool calls don't block the test
RESULT=$(CLAUDE_SESSION_DRIVER_APPROVAL_TIMEOUT=2 bash "$PLUGIN_DIR/scripts/launch-worker.sh" "$TMUX_NAME" /tmp 2>&1)
SESSION_ID=$(echo "$RESULT" | jq -r '.session_id')
WORKER_TMUX_NAME=$(echo "$RESULT" | jq -r '.tmux_name')
EVENTS_FILE=$(echo "$RESULT" | jq -r '.events_file')

if [ -n "$SESSION_ID" ] && [ -n "$WORKER_TMUX_NAME" ] && [ -f "$EVENTS_FILE" ]; then
  pass "Worker launched (session: $SESSION_ID, tmux: $WORKER_TMUX_NAME)"
else
  fail "Worker failed to launch: $RESULT"
  echo "Results: 0/$TESTS passed"
  exit 1
fi

# --- Test 2: Verify session_start event ---
run_test
FIRST_EVENT=$(head -1 "$EVENTS_FILE" | jq -r '.event')
if [ "$FIRST_EVENT" = "session_start" ]; then
  pass "session_start event present"
else
  fail "Expected session_start, got: $FIRST_EVENT"
fi

# --- Test 3: Verify meta file ---
run_test
META_FILE="/tmp/claude-workers/${SESSION_ID}.meta"
if [ -f "$META_FILE" ]; then
  META_TMUX=$(jq -r '.tmux_name' "$META_FILE")
  META_REQUESTED_TMUX=$(jq -r '.requested_tmux_name // empty' "$META_FILE")
  if [ "$META_TMUX" = "$WORKER_TMUX_NAME" ] && [ "$META_REQUESTED_TMUX" = "$TMUX_NAME" ]; then
    pass "Meta file records requested and resolved tmux names"
  elif [ "$META_TMUX" = "$TMUX_NAME" ]; then
    pass "Meta file correct (tmux_name=$META_TMUX)"
  else
    fail "Meta file wrong tmux_name: $META_TMUX (requested=$META_REQUESTED_TMUX)"
  fi
else
  fail "Meta file not found"
fi

# --- Test 4: Verify tmux session exists ---
run_test
if tmux has-session -t "$WORKER_TMUX_NAME" 2>/dev/null; then
  pass "tmux session '$WORKER_TMUX_NAME' exists"
else
  fail "tmux session '$WORKER_TMUX_NAME' not found"
fi

# --- Test 5: Send prompt that triggers tool use, wait for stop ---
run_test
echo "Test 5: Sending prompt (file write)..."
TEST_FILE="/tmp/integration-test-$$.txt"
bash "$PLUGIN_DIR/scripts/send-prompt.sh" "$WORKER_TMUX_NAME" "Write the word 'hello' to $TEST_FILE using the Write tool. Do not read it first."
STOP_EVENT=$(bash "$PLUGIN_DIR/scripts/wait-for-event.sh" "$SESSION_ID" stop 120 2>&1)
STOP_EXIT=$?

if [ $STOP_EXIT -eq 0 ]; then
  pass "Worker processed prompt and stopped"
else
  fail "Worker did not stop within timeout: $STOP_EVENT"
fi

# --- Test 6: Verify event sequence includes pre_tool_use ---
run_test
EVENT_SEQUENCE=$(jq -r '.event' "$EVENTS_FILE" | tr '\n' ',')
if echo "$EVENT_SEQUENCE" | grep -q "session_start,user_prompt_submit,pre_tool_use,"; then
  pass "Event sequence includes pre_tool_use: $EVENT_SEQUENCE"
else
  fail "Unexpected event sequence: $EVENT_SEQUENCE"
fi

# --- Test 7: Verify pre_tool_use event has tool details ---
run_test
PRE_TOOL_EVENTS=$(jq -c 'select(.event=="pre_tool_use")' "$EVENTS_FILE")
if [ -n "$PRE_TOOL_EVENTS" ]; then
  FIRST_TOOL=$(echo "$PRE_TOOL_EVENTS" | head -1 | jq -r '.tool')
  if [ -n "$FIRST_TOOL" ] && [ "$FIRST_TOOL" != "null" ]; then
    pass "pre_tool_use event has tool name: $FIRST_TOOL"
  else
    fail "pre_tool_use event missing tool name"
  fi
else
  fail "No pre_tool_use events found"
fi

# --- Test 8: Verify file was actually written ---
run_test
if [ -f "$TEST_FILE" ]; then
  pass "Worker wrote file $TEST_FILE"
  rm -f "$TEST_FILE"
else
  fail "Worker did not create $TEST_FILE"
fi

# --- Test 9: read-events.sh works on live data ---
run_test
STOP_COUNT=$(bash "$PLUGIN_DIR/scripts/read-events.sh" "$SESSION_ID" --type stop | wc -l | tr -d ' ')
if [ "$STOP_COUNT" -ge 1 ]; then
  pass "read-events.sh --type stop found $STOP_COUNT stop event(s)"
else
  fail "read-events.sh --type stop found no events"
fi

# --- Test 10: Stop worker and verify cleanup ---
run_test
echo "Test 10: Stopping worker..."
bash "$PLUGIN_DIR/scripts/stop-worker.sh" "$WORKER_TMUX_NAME" "$SESSION_ID" 2>&1
# Clear SESSION_ID so cleanup trap doesn't double-stop
STOPPED_SESSION_ID="$SESSION_ID"
SESSION_ID=""

if ! tmux has-session -t "$WORKER_TMUX_NAME" 2>/dev/null; then
  pass "tmux session cleaned up"
else
  fail "tmux session still exists after stop"
fi

# --- Test 11: Verify file cleanup ---
run_test
if [ ! -f "/tmp/claude-workers/${STOPPED_SESSION_ID}.events.jsonl" ] && \
   [ ! -f "/tmp/claude-workers/${STOPPED_SESSION_ID}.meta" ]; then
  pass "Event and meta files cleaned up"
else
  fail "Worker files still exist after stop"
fi

# --- Summary ---
echo ""
echo "Results: $((TESTS - FAILURES))/$TESTS passed"
if [ "$FAILURES" -gt 0 ]; then
  exit 1
fi
echo "Integration test complete!"
