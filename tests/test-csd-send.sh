#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CSD="$SCRIPT_DIR/../skills/driving-claude-code-sessions/scripts/csd"
WDIR=/tmp/csd-workers

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "  PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "  FAIL: $1 - $2"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

TMUX_NAME="test-csd-send"
SID="test-send-001"
META="$WDIR/$SID.meta"
EVENT_FILE="$WDIR/$SID.events.jsonl"
OUTFILE=$(mktemp)
cleanup() {
  tmux kill-session -t "$TMUX_NAME" 2>/dev/null || true
  rm -f "$OUTFILE" "$META" "$EVENT_FILE"
}
trap cleanup EXIT
cleanup
mkdir -p "$WDIR"

echo "{\"tmux_name\":\"$TMUX_NAME\",\"session_id\":\"$SID\",\"cwd\":\"/tmp\"}" > "$META"

# Start a fake worker pane: it appends every received line to OUTFILE, and once
# it has read $EMIT_AFTER lines it writes a user_prompt_submit event to the
# event file -- simulating Claude Code accepting the prompt and the emit-event
# hook recording the submission. EMIT_AFTER=2 simulates the #20 race where the
# first Enter is swallowed and only a retry submits.
start_pane() {
  local emit_after="$1"
  rm -f "$OUTFILE" "$EVENT_FILE"
  : > "$OUTFILE"
  tmux kill-session -t "$TMUX_NAME" 2>/dev/null || true
  tmux new-session -d -s "$TMUX_NAME" \
    "n=0; while IFS= read -r line; do printf '%s\n' \"\$line\" >> $OUTFILE; n=\$((n+1)); if [ -n \"$emit_after\" ] && [ \"\$n\" -ge \"$emit_after\" ]; then printf '%s\n' '{\"ts\":\"t\",\"event\":\"user_prompt_submit\"}' >> $EVENT_FILE; fi; done"
  sleep 0.2
}

# --- Test 1: prompt arrives and send succeeds when submission is confirmed ---
start_pane 1
EC=0
bash "$CSD" --worker "$TMUX_NAME" send "hello world" >/dev/null 2>&1 || EC=$?
[ "$EC" -eq 0 ] && pass "send succeeds when submit event appears" \
  || fail "send confirmed" "exit $EC"
grep -q "hello world" "$OUTFILE" && pass "prompt arrives at tmux pane" \
  || fail "send" "no 'hello world' in $OUTFILE: $(cat "$OUTFILE")"

# --- Test 2: re-send Enter until the prompt is actually submitted (#20) ---
# Pane only emits the submit event after the SECOND line it reads, simulating
# the first Enter being swallowed. send must retry Enter and still succeed.
start_pane 2
EC=0
CSD_SUBMIT_TIMEOUT=5 CSD_SUBMIT_RETRY_INTERVAL=0.5 \
  bash "$CSD" --worker "$TMUX_NAME" send "retry me" >/dev/null 2>&1 || EC=$?
[ "$EC" -eq 0 ] && pass "send retries Enter until submission confirmed" \
  || fail "send retry" "exit $EC"
# Each Enter terminates one read; >=2 lines proves a second Enter was sent.
LINES=$(wc -l < "$OUTFILE" | tr -d ' ')
[ "$LINES" -ge 2 ] && pass "send re-sends Enter on swallowed submit" \
  || fail "send retry enter" "only $LINES line(s) in pane; expected >=2"

# --- Test 3: fail loudly when the prompt is never submitted (#20) ---
# Pane never emits a submit event. send must NOT silently report success.
start_pane ""
EC=0
CSD_SUBMIT_TIMEOUT=1 CSD_SUBMIT_RETRY_INTERVAL=0.5 \
  bash "$CSD" --worker "$TMUX_NAME" send "never submitted" >/dev/null 2>&1 || EC=$?
[ "$EC" -ne 0 ] && pass "send fails loudly when submission never confirmed" \
  || fail "send unconfirmed" "exit 0 despite no submit event"
grep -q "never submitted" "$OUTFILE" && pass "prompt still pasted before failure" \
  || fail "send paste" "paste did not arrive: $(cat "$OUTFILE")"

# --- Test 4: missing tmux session fails ---
tmux kill-session -t "$TMUX_NAME" 2>/dev/null || true
EC=0
bash "$CSD" --worker "$TMUX_NAME" send "x" 2>/dev/null || EC=$?
[ "$EC" -ne 0 ] && pass "missing tmux fails" || fail "missing tmux" "exit 0"

TOTAL=$((PASS_COUNT + FAIL_COUNT))
echo ""
echo "Results: $PASS_COUNT/$TOTAL passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
