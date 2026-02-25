#!/bin/bash
# Integration-style test for tmux namespacing behavior without launching real Claude.
#
# Requirements: tmux, jq

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FAILURES=0
TESTS=0

TMP_DIR="$(mktemp -d)"
MOCK_CLAUDE="$TMP_DIR/mock-claude.sh"
PARENT_SESSION="ns-parent-$$"
PARENT_SESSION_OFF="ns-parent-off-$$"
REQUESTED_NAME="worker"
REQUESTED_NAME_OFF="worker-off"
TEST_NAMESPACE_DELIM="--"
LAUNCH_JSON="$TMP_DIR/launch.json"
LAUNCH_JSON_OFF="$TMP_DIR/launch-off.json"

SESSION_ID=""
SESSION_ID_OFF=""
RESOLVED_NAME=""
RESOLVED_NAME_OFF=""

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

wait_for_file() {
  local path="$1"
  local timeout="${2:-50}"
  for _ in $(seq 1 "$timeout"); do
    if [ -s "$path" ]; then
      return 0
    fi
    sleep 0.2
  done
  return 1
}

cleanup() {
  tmux kill-session -t "$PARENT_SESSION" 2>/dev/null || true
  tmux kill-session -t "$PARENT_SESSION_OFF" 2>/dev/null || true
  if [ -n "$RESOLVED_NAME" ]; then
    tmux kill-session -t "$RESOLVED_NAME" 2>/dev/null || true
  fi
  if [ -n "$RESOLVED_NAME_OFF" ]; then
    tmux kill-session -t "$RESOLVED_NAME_OFF" 2>/dev/null || true
  fi
  if [ -n "$SESSION_ID" ]; then
    rm -f "/tmp/claude-workers/${SESSION_ID}.events.jsonl" "/tmp/claude-workers/${SESSION_ID}.meta"
  fi
  if [ -n "$SESSION_ID_OFF" ]; then
    rm -f "/tmp/claude-workers/${SESSION_ID_OFF}.events.jsonl" "/tmp/claude-workers/${SESSION_ID_OFF}.meta"
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

cat > "$MOCK_CLAUDE" <<'EOF'
#!/bin/bash
set -euo pipefail

SESSION_ID=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --session-id)
      SESSION_ID="${2:-}"
      shift 2
      ;;
    --session-id=*)
      SESSION_ID="${1#--session-id=}"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

if [ -z "$SESSION_ID" ]; then
  echo "mock-claude: missing --session-id" >&2
  exit 1
fi

EVENTS_FILE="/tmp/claude-workers/${SESSION_ID}.events.jsonl"
printf '{"event":"session_start","session_id":"%s"}\n' "$SESSION_ID" >> "$EVENTS_FILE"

while IFS= read -r line; do
  if [ "$line" = "/exit" ]; then
    printf '{"event":"session_end","session_id":"%s"}\n' "$SESSION_ID" >> "$EVENTS_FILE"
    exit 0
  fi
done
EOF
chmod +x "$MOCK_CLAUDE"

RUN_INHERIT="$TMP_DIR/run-inherit.sh"
cat > "$RUN_INHERIT" <<EOF
#!/bin/bash
set -euo pipefail
CLAUDE_SESSION_DRIVER_LAUNCH_CMD="$MOCK_CLAUDE" \
CLAUDE_SESSION_DRIVER_TMUX_NAMESPACE_MODE=inherit \
CLAUDE_SESSION_DRIVER_TMUX_NAMESPACE_DELIM="$TEST_NAMESPACE_DELIM" \
  bash "$PLUGIN_DIR/scripts/launch-worker.sh" "$REQUESTED_NAME" /tmp > "$LAUNCH_JSON"
sleep 15
EOF
chmod +x "$RUN_INHERIT"

EXPECTED_NAME="${PARENT_SESSION}${TEST_NAMESPACE_DELIM}${REQUESTED_NAME}"

echo "=== Test namespacing in tmux ==="

# --- Test 1: Default inherit mode namespaces worker name ---
run_test
if tmux new-session -d -s "$PARENT_SESSION" "$RUN_INHERIT"; then
  if wait_for_file "$LAUNCH_JSON" 100; then
    RESOLVED_NAME="$(jq -r '.tmux_name // empty' "$LAUNCH_JSON")"
    SESSION_ID="$(jq -r '.session_id // empty' "$LAUNCH_JSON")"
    OUTPUT_REQUESTED="$(jq -r '.requested_tmux_name // empty' "$LAUNCH_JSON")"
    if [ "$RESOLVED_NAME" = "$EXPECTED_NAME" ] && [ "$OUTPUT_REQUESTED" = "$REQUESTED_NAME" ] && [ -n "$SESSION_ID" ]; then
      pass "inherit mode prefixes tmux name ($RESOLVED_NAME)"
    else
      fail "unexpected launch output: resolved='$RESOLVED_NAME' requested='$OUTPUT_REQUESTED' session='$SESSION_ID'"
    fi
  else
    fail "launch output file not created for inherit mode"
  fi
else
  fail "failed to create parent tmux session"
fi

# --- Test 2: send-prompt resolves requested name to namespaced session ---
run_test
if [ -n "$SESSION_ID" ] && bash "$PLUGIN_DIR/scripts/send-prompt.sh" "$REQUESTED_NAME" "namespace test prompt" >/dev/null 2>&1; then
  pass "send-prompt accepted requested name in namespaced mode"
else
  fail "send-prompt could not resolve requested name in namespaced mode"
fi

# --- Test 3: stop-worker resolves requested name and cleans up ---
run_test
if [ -n "$SESSION_ID" ] && bash "$PLUGIN_DIR/scripts/stop-worker.sh" "$REQUESTED_NAME" "$SESSION_ID" >/dev/null 2>&1; then
  if ! tmux has-session -t "$EXPECTED_NAME" 2>/dev/null && \
     [ ! -f "/tmp/claude-workers/${SESSION_ID}.events.jsonl" ] && \
     [ ! -f "/tmp/claude-workers/${SESSION_ID}.meta" ]; then
    pass "stop-worker resolved requested name and cleaned up"
  else
    fail "stop-worker did not fully clean up namespaced worker"
  fi
else
  fail "stop-worker failed for namespaced worker"
fi

RUN_OFF="$TMP_DIR/run-off.sh"
cat > "$RUN_OFF" <<EOF
#!/bin/bash
set -euo pipefail
CLAUDE_SESSION_DRIVER_TMUX_NAMESPACE_MODE=off \
CLAUDE_SESSION_DRIVER_LAUNCH_CMD="$MOCK_CLAUDE" \
  bash "$PLUGIN_DIR/scripts/launch-worker.sh" "$REQUESTED_NAME_OFF" /tmp > "$LAUNCH_JSON_OFF"
sleep 15
EOF
chmod +x "$RUN_OFF"

echo "=== Test namespace mode off ==="

# --- Test 4: off mode keeps original name ---
run_test
if tmux new-session -d -s "$PARENT_SESSION_OFF" "$RUN_OFF"; then
  if wait_for_file "$LAUNCH_JSON_OFF" 100; then
    RESOLVED_NAME_OFF="$(jq -r '.tmux_name // empty' "$LAUNCH_JSON_OFF")"
    SESSION_ID_OFF="$(jq -r '.session_id // empty' "$LAUNCH_JSON_OFF")"
    if [ "$RESOLVED_NAME_OFF" = "$REQUESTED_NAME_OFF" ] && [ -n "$SESSION_ID_OFF" ]; then
      pass "off mode keeps tmux name unmodified"
    else
      fail "off mode produced unexpected name '$RESOLVED_NAME_OFF'"
    fi
  else
    fail "launch output file not created for off mode"
  fi
else
  fail "failed to create off-mode parent tmux session"
fi

# --- Test 5: off mode stop-worker cleanup still works ---
run_test
if [ -n "$SESSION_ID_OFF" ] && bash "$PLUGIN_DIR/scripts/stop-worker.sh" "$REQUESTED_NAME_OFF" "$SESSION_ID_OFF" >/dev/null 2>&1; then
  if ! tmux has-session -t "$REQUESTED_NAME_OFF" 2>/dev/null && \
     [ ! -f "/tmp/claude-workers/${SESSION_ID_OFF}.events.jsonl" ] && \
     [ ! -f "/tmp/claude-workers/${SESSION_ID_OFF}.meta" ]; then
    pass "off mode worker stopped cleanly"
  else
    fail "off mode worker still running after stop"
  fi
else
  fail "off mode stop-worker failed"
fi

echo ""
echo "Results: $((TESTS - FAILURES))/$TESTS passed"
if [ "$FAILURES" -gt 0 ]; then
  exit 1
fi
echo "tmux namespace tests complete!"
