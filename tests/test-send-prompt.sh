#!/bin/bash
# Tests for scripts/send-prompt.sh
#
# Regression coverage for SUP-239: when sending a long prompt to a Claude Code
# worker, the Enter must arrive after the TUI has exited its paste-input state.
# The script now wraps the prompt in bracketed-paste markers (\x1B[200~ ...
# \x1B[201~) and delays Enter, matching the pattern Anthropic's own SDK uses
# when driving a Claude Code TUI via a child pty.
#
# Strategy: run a stdin-byte timestamper inside a tmux session, fire
# send-prompt.sh at it, and assert on both the byte sequence and the
# millisecond gap between the paste-end marker and the Enter byte.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SEND_PROMPT="$PLUGIN_DIR/skills/driving-claude-code-sessions/scripts/send-prompt.sh"
RECORDER="$SCRIPT_DIR/helpers/timestamp-stdin.py"

TMUX_NAME="send-prompt-test-$$"
LOG_FILE="/tmp/send-prompt-test-$$.log"

FAILURES=0
TESTS=0

fail() { echo "FAIL: $1"; FAILURES=$((FAILURES+1)); }
pass() { echo "PASS: $1"; }
run_test() { TESTS=$((TESTS+1)); }

cleanup() {
  tmux kill-session -t "$TMUX_NAME" 2>/dev/null || true
  rm -f "$LOG_FILE"
}
trap cleanup EXIT

start_recorder() {
  rm -f "$LOG_FILE"
  tmux new-session -d -s "$TMUX_NAME" "python3 $RECORDER > $LOG_FILE"
  # Wait for python to be ready before sending keys.
  sleep 0.3
}

# Hex sequence of bytes received, space-separated.
hex_sequence() {
  awk '{printf "%s ", $2}' "$LOG_FILE"
}

# Timestamp (ms) of the last 0x0d (CR/Enter) byte.
last_cr_ts() {
  awk '$2=="0d"{ts=$1} END{print ts}' "$LOG_FILE"
}

# Timestamp (ms) of the last byte of the paste-end marker (the trailing 0x7e
# preceded by 0x32 0x30 0x31).
paste_end_ts() {
  awk '
    {
      ts[NR]=$1; b[NR]=$2;
      if ($2=="7e" && b[NR-1]=="31" && b[NR-2]=="30" && b[NR-3]=="32" && b[NR-4]=="5b" && b[NR-5]=="1b") {
        last_end=$1
      }
    }
    END { print last_end }
  ' "$LOG_FILE"
}

# --- Test 1: bracketed-paste wrap surrounds the prompt ---
run_test
echo "Test 1: Prompt is wrapped in \\x1B[200~ ... \\x1B[201~ markers..."
start_recorder
bash "$SEND_PROMPT" "$TMUX_NAME" "hello"
sleep 0.3
tmux kill-session -t "$TMUX_NAME" 2>/dev/null || true

# Expected: 1b 5b 32 30 30 7e (start) 68 65 6c 6c 6f (hello) 1b 5b 32 30 31 7e (end) ... 0d (Enter)
EXPECTED="1b 5b 32 30 30 7e 68 65 6c 6c 6f 1b 5b 32 30 31 7e 0d "
ACTUAL="$(hex_sequence)"
if [ "$ACTUAL" = "$EXPECTED" ]; then
  pass "Byte sequence matches bracketed-paste-wrapped prompt + Enter"
else
  fail "Byte sequence mismatch"
  echo "  expected: $EXPECTED" >&2
  echo "  actual:   $ACTUAL" >&2
fi

# --- Test 2: default settle puts a gap between paste-end and Enter ---
run_test
echo "Test 2: Default settle (0.1s) leaves a gap before Enter..."
start_recorder
LONG_PROMPT=$(python3 -c '
for i in range(1, 31):
    print(f"Line {i}: lorem ipsum dolor sit amet, em dash — and more text here.")
')
bash "$SEND_PROMPT" "$TMUX_NAME" "$LONG_PROMPT"
sleep 0.3
tmux kill-session -t "$TMUX_NAME" 2>/dev/null || true

CR_TS=$(last_cr_ts)
END_TS=$(paste_end_ts)
if [ -z "$CR_TS" ] || [ -z "$END_TS" ]; then
  fail "Did not capture both paste-end marker and Enter (end=$END_TS cr=$CR_TS)"
  tail -3 "$LOG_FILE" >&2 || true
else
  GAP=$((CR_TS - END_TS))
  # Default settle is 0.1s = 100ms. Allow 20ms slack downward; no upper bound
  # — gap-too-small is the bug we care about, gap-too-large just means a
  # loaded test runner, not a regression.
  if [ "$GAP" -ge 80 ]; then
    pass "Gap between paste-end and Enter is ${GAP}ms (>=80ms)"
  else
    fail "Gap is only ${GAP}ms (expected >=80ms with default 0.1s settle)"
  fi
fi

# --- Test 3: ordering — Enter never precedes the paste-end marker ---
run_test
echo "Test 3: Enter is always sent after the paste-end marker..."
start_recorder
bash "$SEND_PROMPT" "$TMUX_NAME" "abcdefghij"
sleep 0.3
tmux kill-session -t "$TMUX_NAME" 2>/dev/null || true

CR_TS=$(last_cr_ts)
END_TS=$(paste_end_ts)
if [ -z "$CR_TS" ] || [ -z "$END_TS" ]; then
  fail "Did not capture both paste-end and Enter"
elif [ "$CR_TS" -ge "$END_TS" ]; then
  pass "Enter (t=$CR_TS) arrived after paste-end (t=$END_TS)"
else
  fail "Enter arrived BEFORE paste-end (cr=$CR_TS end=$END_TS)"
fi

# --- Test 4: paste-end markers in the prompt are stripped, not pasted ---
run_test
echo "Test 4: Embedded paste-end markers in prompt are sanitized..."
start_recorder
EVIL_PROMPT="hello"$'\x1b'"[201~world"
bash "$SEND_PROMPT" "$TMUX_NAME" "$EVIL_PROMPT"
sleep 0.3
tmux kill-session -t "$TMUX_NAME" 2>/dev/null || true

# Concatenate received hex bytes; the byte sequence "1b 5b 32 30 31 7e" (the
# paste-end marker) should appear exactly ONCE — the one we sent ourselves
# at the end of the payload. If sanitization fails, it'll appear twice
# (once inside the prompt body, once at the end), and the prompt would have
# closed paste mode early.
SEQ=$(awk '{printf "%s ",$2}' "$LOG_FILE")
COUNT=$(printf '%s' "$SEQ" | grep -oE '1b 5b 32 30 31 7e' | wc -l | tr -d ' ')
if [ "$COUNT" = "1" ]; then
  pass "Embedded paste-end marker stripped (saw 1 trailing marker, no leak)"
else
  fail "Expected exactly 1 paste-end marker in stream, saw $COUNT (sanitization failed)"
fi

echo ""
echo "Results: $((TESTS - FAILURES))/$TESTS passed"
if [ "$FAILURES" -gt 0 ]; then
  exit 1
fi
exit 0
