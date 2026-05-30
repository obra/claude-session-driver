#!/bin/bash
# Tests for the converse-timeout diagnostic dump (PRI-1922). When CSD_CONVERSE_DIAG_FILE
# is set in the environment, csd's cmd_converse writes a post-mortem snapshot before
# exiting on timeout. When unset, behavior is unchanged (no diagnostic file).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CSD="$SCRIPT_DIR/../skills/driving-claude-code-sessions/scripts/csd"
WDIR=/tmp/claude-workers

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1${2:+ - $2}"; FAIL=$((FAIL+1)); }

TMUX_NAME="test-csd-diag"
SID="test-diag-001"
DIAG_FILE=""
FAKE_HOME=""
cleanup() {
  tmux kill-session -t "$TMUX_NAME" 2>/dev/null || true
  rm -f "$WDIR/$SID.meta" "$WDIR/$SID.events.jsonl"
  [ -n "$FAKE_HOME" ] && rm -rf "$FAKE_HOME"
  [ -n "$DIAG_FILE" ] && rm -f "$DIAG_FILE"
}
trap cleanup EXIT
cleanup

FAKE_HOME=$(mktemp -d)
FAKE_HOME=$(cd "$FAKE_HOME" && pwd -P)
CWD="$FAKE_HOME/proj"; mkdir -p "$CWD"
CWD=$(cd "$CWD" && pwd -P)
ENC=$(echo "$CWD" | sed 's|/|-|g')
LOG_DIR="$FAKE_HOME/.claude/projects/$ENC"
mkdir -p "$LOG_DIR" "$WDIR"
LOG="$LOG_DIR/$SID.jsonl"
EVENT_FILE="$WDIR/$SID.events.jsonl"

# Real tmux session that swallows input. Worker meta + initial event file so
# cmd_converse can find them; no assistant response is ever produced -> timeout.
tmux new-session -d -s "$TMUX_NAME" 'cat >/dev/null'
echo "{\"tmux_name\":\"$TMUX_NAME\",\"session_id\":\"$SID\",\"cwd\":\"$CWD\"}" > "$WDIR/$SID.meta"
echo '{"ts":"t0","event":"session_start","cwd":"'"$CWD"'"}' > "$EVENT_FILE"
cat > "$LOG" <<'JSON'
{"type":"user","message":{"content":"first prompt"}}
{"type":"assistant","message":{"content":[{"type":"text","text":"first response"}]}}
JSON

# Run converse with a short timeout (1s) so the test is fast.
# WORKER is passed via --worker; CSD_CONVERSE_DIAG_FILE is what triggers the dump.

# 1. Baseline: WITHOUT CSD_CONVERSE_DIAG_FILE, no diagnostic file is created.
err1=$(HOME="$FAKE_HOME" "$CSD" --worker "$SID" converse "test prompt 1" 1 2>&1 >/dev/null || true)
echo "$err1" | grep -q "Worker did not finish within 1s" && pass "baseline: timeout error emitted" \
  || fail "baseline: expected timeout error in stderr" "got: $err1"
echo "$err1" | grep -q "csd-diagnostic:" && fail "baseline: should NOT emit csd-diagnostic pointer" "got: $err1" \
  || pass "baseline: no diagnostic pointer when env unset"

# 2. With CSD_CONVERSE_DIAG_FILE set: file is created with expected sections.
DIAG_FILE="$FAKE_HOME/diag1.txt"
err2=$(CSD_CONVERSE_DIAG_FILE="$DIAG_FILE" HOME="$FAKE_HOME" "$CSD" --worker "$SID" converse "test prompt 2" 1 2>&1 >/dev/null || true)
echo "$err2" | grep -q "Worker did not finish within 1s" && pass "with env: timeout error still emitted" \
  || fail "with env: expected timeout error" "got: $err2"
echo "$err2" | grep -q "csd-diagnostic: $DIAG_FILE" && pass "with env: stderr points at diag file" \
  || fail "with env: expected 'csd-diagnostic: $DIAG_FILE' in stderr" "got: $err2"
[ -f "$DIAG_FILE" ] && pass "diag file created at $DIAG_FILE" \
  || fail "diag file missing" "expected $DIAG_FILE"

# 3. Diagnostic contents include the expected sections.
diag=$(cat "$DIAG_FILE" 2>/dev/null || echo "")
for needle in \
  "csd converse diagnostic" \
  "reason=wait_for_turn_timeout" \
  "session_id=$SID" \
  "ps -eHo" \
  "tmux capture-pane" \
  "claude session JSONL tail" \
  "csd events JSONL tail" \
  "end csd diagnostic"
do
  echo "$diag" | grep -qF "$needle" && pass "diag contains: $needle" \
    || fail "diag missing section: $needle"
done

# 4. Diagnostic captured the tmux session (it's live, so capture should have output).
# We won't assert specific content (depends on shell prompt), but should not say "not present".
echo "$diag" | grep -A2 "tmux capture-pane" | grep -q "not present" \
  && fail "diag should have captured live tmux session" "got 'not present' marker" \
  || pass "diag captured live tmux session content"

# 5. Diagnostic captured the existing log file (LOG has 2 lines).
echo "$diag" | grep -A3 "claude session JSONL tail" | grep -q "first response" \
  && pass "diag includes log tail content" \
  || fail "diag did not capture log tail" "log was at $LOG"

# 6. Diagnostic captured the events file (1 line: session_start).
echo "$diag" | grep -A3 "csd events JSONL tail" | grep -q "session_start" \
  && pass "diag includes events tail content" \
  || fail "diag did not capture events tail"

# 7. Second timeout path: no_assistant_response. cmd_wait_for_turn SUCCEEDS (a stop
# event arrives) but the assistant never produces text within ~2s of polling. To
# trigger it: append a stop event to the events file after csd starts polling so
# wait_for_turn returns 0, but never grow the assistant message count in $LOG.
DIAG_FILE2="$FAKE_HOME/diag2.txt"
EVENT_FILE2="$WDIR/$SID.events.jsonl"
# Reset events file so the seeded line below is the only post-prompt event.
echo '{"ts":"t0","event":"session_start","cwd":"'"$CWD"'"}' > "$EVENT_FILE2"
# Inject a stop event 0.5s after converse starts polling — wait_for_turn will see it
# and return 0; converse will then poll $LOG for new assistant text and time out.
( sleep 0.5; echo '{"ts":"t1","event":"stop"}' >> "$EVENT_FILE2" ) &
INJECT_PID=$!
err3=$(CSD_CONVERSE_DIAG_FILE="$DIAG_FILE2" HOME="$FAKE_HOME" "$CSD" --worker "$SID" converse "test prompt 3" 5 2>&1 >/dev/null || true)
wait "$INJECT_PID" 2>/dev/null || true
echo "$err3" | grep -q "Timed out waiting for assistant response" && pass "no_assistant_response: error emitted" \
  || fail "no_assistant_response: expected assistant-response timeout error" "got: $err3"
echo "$err3" | grep -q "csd-diagnostic: $DIAG_FILE2" && pass "no_assistant_response: stderr points at diag file" \
  || fail "no_assistant_response: expected diag pointer in stderr" "got: $err3"
[ -f "$DIAG_FILE2" ] && pass "no_assistant_response: diag file created" \
  || fail "no_assistant_response: diag file missing" "expected $DIAG_FILE2"
grep -q "reason=no_assistant_response" "$DIAG_FILE2" 2>/dev/null \
  && pass "no_assistant_response: diag carries the right reason" \
  || fail "no_assistant_response: expected reason=no_assistant_response in diag" "got: $(head -5 "$DIAG_FILE2" 2>&1)"
rm -f "$DIAG_FILE2"

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
