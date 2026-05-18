#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CSD="$SCRIPT_DIR/../skills/driving-claude-code-sessions/scripts/csd"
WDIR=/tmp/claude-workers

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "  PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "  FAIL: $1 - $2"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

cleanup() {
  rm -f "$WDIR/test-list-001.meta" "$WDIR/test-list-001.events.jsonl"
  rm -f "$WDIR/test-list-002.meta"
  rm -f "$WDIR/bin/test-list-alive"
  tmux kill-session -t test-list-alive 2>/dev/null || true
}
trap cleanup EXIT
mkdir -p "$WDIR/bin"

# --- Test 1: shows live workers with rich status, hides gone ones ---
echo "Test 1: live workers shown by default, gone ones hidden"
# Live worker — give it an events file so status resolves to 'idle'
tmux new-session -d -s test-list-alive -c /tmp 'sleep 60'
echo '{"tmux_name":"test-list-alive","session_id":"test-list-001","cwd":"/tmp","started_at":"2025-01-01T00:00:00Z"}' > "$WDIR/test-list-001.meta"
echo '{"ts":"t0","event":"stop"}' > "$WDIR/test-list-001.events.jsonl"
touch "$WDIR/bin/test-list-alive"
# Dead worker — no tmux session, so status='gone'
echo '{"tmux_name":"test-list-dead","session_id":"test-list-002","cwd":"/tmp","started_at":"2025-01-01T00:00:00Z"}' > "$WDIR/test-list-002.meta"

OUTPUT=$(bash "$CSD" list 2>&1)
if echo "$OUTPUT" | grep -q "test-list-alive"; then
  pass "live worker listed"
else
  fail "live missing" "$OUTPUT"
fi
if echo "$OUTPUT" | grep -q "test-list-dead"; then
  fail "gone included by default" "should be excluded without --all"
else
  pass "gone worker excluded by default"
fi
if echo "$OUTPUT" | grep -q "/tmp/claude-workers/bin/test-list-alive"; then
  pass "shim path included in output"
else
  fail "shim path" "expected shim path in row, got: $OUTPUT"
fi
# New: the live worker's row should report 'idle', not the old 'alive'
if echo "$OUTPUT" | grep -qE "^idle\s+test-list-alive\b"; then
  pass "live worker reports rich status (idle)"
else
  fail "rich status" "expected 'idle' for live worker, got: $OUTPUT"
fi

# --- Test 2: --all includes gone workers ---
echo "Test 2: --all includes gone"
OUTPUT=$(bash "$CSD" list --all 2>&1)
if echo "$OUTPUT" | grep -q "test-list-dead"; then
  pass "gone worker included with --all"
else
  fail "gone with --all" "$OUTPUT"
fi
if echo "$OUTPUT" | grep -qE "^gone\s+test-list-dead\b"; then
  pass "gone worker reports status='gone'"
else
  fail "gone status" "expected 'gone' for dead worker, got: $OUTPUT"
fi

# --- Test 3: output has a header line ---
echo "Test 3: header row"
OUTPUT=$(bash "$CSD" list --all 2>&1)
if echo "$OUTPUT" | head -1 | grep -qE "STATUS.*TMUX.*SHIM"; then
  pass "header row present"
else
  fail "header" "first line: $(echo "$OUTPUT" | head -1)"
fi

# --- Test 4: pattern filter ---
echo "Test 4: pattern filter narrows by substring"
OUTPUT=$(bash "$CSD" list --all test-list-alive 2>&1)
if echo "$OUTPUT" | grep -q "test-list-alive"; then
  pass "pattern matches the worker"
else
  fail "filter match" "expected test-list-alive, got: $OUTPUT"
fi
if echo "$OUTPUT" | grep -q "test-list-dead"; then
  fail "filter leak" "test-list-dead should be filtered out, got: $OUTPUT"
else
  pass "non-matching workers excluded"
fi
# A pattern that matches neither test worker should produce only the header
OUTPUT=$(bash "$CSD" list --all nonexistent-prefix-xyz 2>&1)
LINE_COUNT=$(echo "$OUTPUT" | wc -l | tr -d ' ')
if [ "$LINE_COUNT" = "1" ]; then
  pass "non-matching pattern shows header only"
else
  fail "filter empty" "expected 1 line, got $LINE_COUNT lines: $OUTPUT"
fi

TOTAL=$((PASS_COUNT + FAIL_COUNT))
echo ""
echo "Results: $PASS_COUNT/$TOTAL passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
