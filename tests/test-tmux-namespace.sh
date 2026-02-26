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
PARENT_SESSION_DUP_A="ns-parent-dup-a-$$"
PARENT_SESSION_DUP_B="ns-parent-dup-b-$$"
PARENT_SESSION_WINDOW="ns-parent-window-$$"
REQUESTED_NAME="worker"
REQUESTED_NAME_OFF="worker-off"
REQUESTED_NAME_DUP="worker-dup"
REQUESTED_NAME_WINDOW="worker-window"
TEST_NAMESPACE_DELIM="--"
LAUNCH_JSON="$TMP_DIR/launch.json"
LAUNCH_JSON_OFF="$TMP_DIR/launch-off.json"
LAUNCH_JSON_DUP_A="$TMP_DIR/launch-dup-a.json"
LAUNCH_JSON_DUP_B="$TMP_DIR/launch-dup-b.json"
LAUNCH_JSON_WINDOW="$TMP_DIR/launch-window.json"

SESSION_ID=""
SESSION_ID_OFF=""
SESSION_ID_DUP_A=""
SESSION_ID_DUP_B=""
SESSION_ID_WINDOW=""
RESOLVED_NAME=""
RESOLVED_NAME_OFF=""
RESOLVED_NAME_DUP_A=""
RESOLVED_NAME_DUP_B=""
RESOLVED_NAME_WINDOW=""
EXPECTED_NAME_DUP_A=""
EXPECTED_NAME_DUP_B=""
EXPECTED_NAME_WINDOW=""

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
  tmux kill-session -t "$PARENT_SESSION_DUP_A" 2>/dev/null || true
  tmux kill-session -t "$PARENT_SESSION_DUP_B" 2>/dev/null || true
  tmux kill-session -t "$PARENT_SESSION_WINDOW" 2>/dev/null || true
  if [ -n "$RESOLVED_NAME" ]; then
    tmux kill-session -t "$RESOLVED_NAME" 2>/dev/null || true
  fi
  if [ -n "$RESOLVED_NAME_OFF" ]; then
    tmux kill-session -t "$RESOLVED_NAME_OFF" 2>/dev/null || true
  fi
  if [ -n "$RESOLVED_NAME_DUP_A" ]; then
    tmux kill-session -t "$RESOLVED_NAME_DUP_A" 2>/dev/null || true
  fi
  if [ -n "$RESOLVED_NAME_DUP_B" ]; then
    tmux kill-session -t "$RESOLVED_NAME_DUP_B" 2>/dev/null || true
  fi
  if [ -n "$SESSION_ID" ]; then
    rm -f "/tmp/claude-workers/${SESSION_ID}.events.jsonl" "/tmp/claude-workers/${SESSION_ID}.meta"
  fi
  if [ -n "$SESSION_ID_OFF" ]; then
    rm -f "/tmp/claude-workers/${SESSION_ID_OFF}.events.jsonl" "/tmp/claude-workers/${SESSION_ID_OFF}.meta"
  fi
  if [ -n "$SESSION_ID_DUP_A" ]; then
    rm -f "/tmp/claude-workers/${SESSION_ID_DUP_A}.events.jsonl" "/tmp/claude-workers/${SESSION_ID_DUP_A}.meta"
  fi
  if [ -n "$SESSION_ID_DUP_B" ]; then
    rm -f "/tmp/claude-workers/${SESSION_ID_DUP_B}.events.jsonl" "/tmp/claude-workers/${SESSION_ID_DUP_B}.meta"
  fi
  if [ -n "$SESSION_ID_WINDOW" ]; then
    rm -f "/tmp/claude-workers/${SESSION_ID_WINDOW}.events.jsonl" "/tmp/claude-workers/${SESSION_ID_WINDOW}.meta"
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

RUN_DUP_A="$TMP_DIR/run-dup-a.sh"
cat > "$RUN_DUP_A" <<EOF
#!/bin/bash
set -euo pipefail
CLAUDE_SESSION_DRIVER_LAUNCH_CMD="$MOCK_CLAUDE" \
CLAUDE_SESSION_DRIVER_TMUX_NAMESPACE_MODE=inherit \
CLAUDE_SESSION_DRIVER_TMUX_NAMESPACE_DELIM="$TEST_NAMESPACE_DELIM" \
  bash "$PLUGIN_DIR/scripts/launch-worker.sh" "$REQUESTED_NAME_DUP" /tmp > "$LAUNCH_JSON_DUP_A"
sleep 15
EOF
chmod +x "$RUN_DUP_A"

RUN_DUP_B="$TMP_DIR/run-dup-b.sh"
cat > "$RUN_DUP_B" <<EOF
#!/bin/bash
set -euo pipefail
CLAUDE_SESSION_DRIVER_LAUNCH_CMD="$MOCK_CLAUDE" \
CLAUDE_SESSION_DRIVER_TMUX_NAMESPACE_MODE=inherit \
CLAUDE_SESSION_DRIVER_TMUX_NAMESPACE_DELIM="$TEST_NAMESPACE_DELIM" \
  bash "$PLUGIN_DIR/scripts/launch-worker.sh" "$REQUESTED_NAME_DUP" /tmp > "$LAUNCH_JSON_DUP_B"
sleep 15
EOF
chmod +x "$RUN_DUP_B"

EXPECTED_NAME_DUP_A="${PARENT_SESSION_DUP_A}${TEST_NAMESPACE_DELIM}${REQUESTED_NAME_DUP}"
EXPECTED_NAME_DUP_B="${PARENT_SESSION_DUP_B}${TEST_NAMESPACE_DELIM}${REQUESTED_NAME_DUP}"

echo "=== Test duplicate requested names ==="

# --- Test 6: duplicate requested names can coexist across namespaces ---
run_test
if tmux new-session -d -s "$PARENT_SESSION_DUP_A" "$RUN_DUP_A" && \
   tmux new-session -d -s "$PARENT_SESSION_DUP_B" "$RUN_DUP_B"; then
  if wait_for_file "$LAUNCH_JSON_DUP_A" 100 && wait_for_file "$LAUNCH_JSON_DUP_B" 100; then
    RESOLVED_NAME_DUP_A="$(jq -r '.tmux_name // empty' "$LAUNCH_JSON_DUP_A")"
    RESOLVED_NAME_DUP_B="$(jq -r '.tmux_name // empty' "$LAUNCH_JSON_DUP_B")"
    SESSION_ID_DUP_A="$(jq -r '.session_id // empty' "$LAUNCH_JSON_DUP_A")"
    SESSION_ID_DUP_B="$(jq -r '.session_id // empty' "$LAUNCH_JSON_DUP_B")"
    if [ "$RESOLVED_NAME_DUP_A" = "$EXPECTED_NAME_DUP_A" ] && \
       [ "$RESOLVED_NAME_DUP_B" = "$EXPECTED_NAME_DUP_B" ] && \
       [ -n "$SESSION_ID_DUP_A" ] && [ -n "$SESSION_ID_DUP_B" ]; then
      pass "duplicate requested names resolved into unique namespaced sessions"
    else
      fail "unexpected duplicate launch output: a='$RESOLVED_NAME_DUP_A' b='$RESOLVED_NAME_DUP_B'"
    fi
  else
    fail "duplicate launch output files not created"
  fi
else
  fail "failed to create duplicate parent tmux sessions"
fi

# --- Test 7: send-prompt can target duplicate names using session_id (A) ---
run_test
if [ -n "$SESSION_ID_DUP_A" ] && \
   bash "$PLUGIN_DIR/scripts/send-prompt.sh" "$REQUESTED_NAME_DUP" "duplicate namespace prompt A" "$SESSION_ID_DUP_A" >/dev/null 2>&1; then
  pass "send-prompt targeted worker A by session_id"
else
  fail "send-prompt failed to target worker A by session_id"
fi

# --- Test 8: send-prompt can target duplicate names using session_id (B) ---
run_test
if [ -n "$SESSION_ID_DUP_B" ] && \
   bash "$PLUGIN_DIR/scripts/send-prompt.sh" "$REQUESTED_NAME_DUP" "duplicate namespace prompt B" "$SESSION_ID_DUP_B" >/dev/null 2>&1; then
  pass "send-prompt targeted worker B by session_id"
else
  fail "send-prompt failed to target worker B by session_id"
fi

# --- Test 8b: invalid session_id must not route to duplicate worker ---
run_test
if bash "$PLUGIN_DIR/scripts/send-prompt.sh" "$REQUESTED_NAME_DUP" "duplicate namespace prompt invalid" "missing-session-id" >/dev/null 2>&1; then
  fail "send-prompt should fail for unknown session_id in duplicate-name mode"
else
  pass "send-prompt rejects unknown session_id in duplicate-name mode"
fi

# --- Test 8c: duplicate requested name without session_id requires disambiguation ---
run_test
DUPLICATE_ERR_FILE="$TMP_DIR/duplicate-no-session.err"
if bash "$PLUGIN_DIR/scripts/send-prompt.sh" "$REQUESTED_NAME_DUP" "duplicate namespace prompt no session id" >/dev/null 2>"$DUPLICATE_ERR_FILE"; then
  fail "send-prompt should fail for duplicate names without session_id"
elif grep -q "workers match requested name '$REQUESTED_NAME_DUP'" "$DUPLICATE_ERR_FILE"; then
  pass "send-prompt reports disambiguation guidance for duplicate names"
else
  fail "send-prompt duplicate-name error did not include disambiguation guidance"
fi

# --- Test 9: stop-worker cleanup for duplicate session A ---
run_test
if [ -n "$SESSION_ID_DUP_A" ] && bash "$PLUGIN_DIR/scripts/stop-worker.sh" "$REQUESTED_NAME_DUP" "$SESSION_ID_DUP_A" >/dev/null 2>&1; then
  if ! tmux has-session -t "$EXPECTED_NAME_DUP_A" 2>/dev/null && \
     [ ! -f "/tmp/claude-workers/${SESSION_ID_DUP_A}.events.jsonl" ] && \
     [ ! -f "/tmp/claude-workers/${SESSION_ID_DUP_A}.meta" ]; then
    pass "duplicate session A stopped and cleaned up"
  else
    fail "duplicate session A cleanup incomplete"
  fi
else
  fail "stop-worker failed for duplicate session A"
fi

# --- Test 10: stop-worker cleanup for duplicate session B ---
run_test
if [ -n "$SESSION_ID_DUP_B" ] && bash "$PLUGIN_DIR/scripts/stop-worker.sh" "$REQUESTED_NAME_DUP" "$SESSION_ID_DUP_B" >/dev/null 2>&1; then
  if ! tmux has-session -t "$EXPECTED_NAME_DUP_B" 2>/dev/null && \
     [ ! -f "/tmp/claude-workers/${SESSION_ID_DUP_B}.events.jsonl" ] && \
     [ ! -f "/tmp/claude-workers/${SESSION_ID_DUP_B}.meta" ]; then
    pass "duplicate session B stopped and cleaned up"
  else
    fail "duplicate session B cleanup incomplete"
  fi
else
  fail "stop-worker failed for duplicate session B"
fi

RUN_WINDOW="$TMP_DIR/run-window.sh"
cat > "$RUN_WINDOW" <<EOF
#!/bin/bash
set -euo pipefail
CLAUDE_SESSION_DRIVER_LAUNCH_CMD="$MOCK_CLAUDE" \
CLAUDE_SESSION_DRIVER_TMUX_NAMESPACE_MODE=inherit \
CLAUDE_SESSION_DRIVER_TMUX_SCOPE=window \
  bash "$PLUGIN_DIR/scripts/launch-worker.sh" "$REQUESTED_NAME_WINDOW" /tmp > "$LAUNCH_JSON_WINDOW"
sleep 15
EOF
chmod +x "$RUN_WINDOW"

EXPECTED_NAME_WINDOW="${PARENT_SESSION_WINDOW}:${REQUESTED_NAME_WINDOW}"

echo "=== Test window scope ==="

# --- Test 11: window scope launches in parent session window ---
run_test
if tmux new-session -d -s "$PARENT_SESSION_WINDOW" "$RUN_WINDOW"; then
  if wait_for_file "$LAUNCH_JSON_WINDOW" 100; then
    RESOLVED_NAME_WINDOW="$(jq -r '.tmux_name // empty' "$LAUNCH_JSON_WINDOW")"
    SESSION_ID_WINDOW="$(jq -r '.session_id // empty' "$LAUNCH_JSON_WINDOW")"
    OUTPUT_SCOPE_WINDOW="$(jq -r '.tmux_scope // empty' "$LAUNCH_JSON_WINDOW")"
    if [ "$RESOLVED_NAME_WINDOW" = "$EXPECTED_NAME_WINDOW" ] && \
       [ "$OUTPUT_SCOPE_WINDOW" = "window" ] && \
       [ -n "$SESSION_ID_WINDOW" ] && \
       tmux list-windows -t "$PARENT_SESSION_WINDOW" -F '#W' | grep -Fxq "$REQUESTED_NAME_WINDOW"; then
      pass "window scope launched worker window in parent session"
    else
      fail "unexpected window launch output: target='$RESOLVED_NAME_WINDOW' scope='$OUTPUT_SCOPE_WINDOW' session='$SESSION_ID_WINDOW'"
    fi
  else
    fail "window launch output file not created"
  fi
else
  fail "failed to create window-scope parent tmux session"
fi

# --- Test 12: send-prompt targets window scope worker ---
run_test
if [ -n "$SESSION_ID_WINDOW" ] && \
   bash "$PLUGIN_DIR/scripts/send-prompt.sh" "$REQUESTED_NAME_WINDOW" "window scope prompt" "$SESSION_ID_WINDOW" >/dev/null 2>&1; then
  pass "send-prompt targeted window worker by session_id"
else
  fail "send-prompt failed for window scope worker"
fi

# --- Test 13: stop-worker removes worker window and keeps parent session ---
run_test
if [ -n "$SESSION_ID_WINDOW" ] && bash "$PLUGIN_DIR/scripts/stop-worker.sh" "$REQUESTED_NAME_WINDOW" "$SESSION_ID_WINDOW" >/dev/null 2>&1; then
  if tmux has-session -t "$PARENT_SESSION_WINDOW" 2>/dev/null && \
     ! tmux list-panes -t "$EXPECTED_NAME_WINDOW" >/dev/null 2>&1 && \
     [ ! -f "/tmp/claude-workers/${SESSION_ID_WINDOW}.events.jsonl" ] && \
     [ ! -f "/tmp/claude-workers/${SESSION_ID_WINDOW}.meta" ]; then
    pass "window scope stop-worker removed window and kept parent session"
  else
    fail "window scope cleanup failed"
  fi
else
  fail "stop-worker failed for window scope worker"
fi

echo ""
echo "Results: $((TESTS - FAILURES))/$TESTS passed"
if [ "$FAILURES" -gt 0 ]; then
  exit 1
fi
echo "tmux namespace tests complete!"
