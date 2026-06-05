#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CSD="$SCRIPT_DIR/../skills/driving-claude-code-sessions/scripts/csd"
WDIR=/tmp/csd-workers

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "  PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "  FAIL: $1 - $2"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

cleanup() {
  rm -f "$WDIR"/test-wt-*.meta "$WDIR"/test-wt-*.events.jsonl
  jobs -p 2>/dev/null | xargs kill 2>/dev/null || true
}
trap cleanup EXIT
cleanup
mkdir -p "$WDIR"

# --- matches existing stop ---
echo '{"tmux_name":"test-wt-1","session_id":"test-wt-001","cwd":"/tmp"}' > "$WDIR/test-wt-001.meta"
echo '{"ts":"t1","event":"stop"}' > "$WDIR/test-wt-001.events.jsonl"
OUT=$(bash "$CSD" --worker test-wt-1 wait-for-turn 5)
EC=$?
[ "$EC" = "0" ] && pass "matches existing stop" || fail "stop existing" "exit $EC"
echo "$OUT" | jq -r '.event' | grep -q '^stop$' && pass "stop event returned" || fail "event field" "$OUT"

# --- matches existing session_end ---
echo '{"tmux_name":"test-wt-2","session_id":"test-wt-002","cwd":"/tmp"}' > "$WDIR/test-wt-002.meta"
echo '{"ts":"t1","event":"session_end"}' > "$WDIR/test-wt-002.events.jsonl"
OUT=$(bash "$CSD" --worker test-wt-2 wait-for-turn 5)
echo "$OUT" | jq -r '.event' | grep -q '^session_end$' && pass "matches session_end" || fail "session_end" "$OUT"

# --- matches stop appended later ---
echo '{"tmux_name":"test-wt-3","session_id":"test-wt-003","cwd":"/tmp"}' > "$WDIR/test-wt-003.meta"
echo '{"ts":"t0","event":"session_start","cwd":"/tmp"}' > "$WDIR/test-wt-003.events.jsonl"
(sleep 1 && echo '{"ts":"t1","event":"stop"}' >> "$WDIR/test-wt-003.events.jsonl") &
OUT=$(bash "$CSD" --worker test-wt-3 wait-for-turn 5)
echo "$OUT" | jq -r '.event' | grep -q '^stop$' && pass "matches stop appended later" || fail "late stop" "$OUT"

# --- skips earlier stop with --after-line ---
echo '{"tmux_name":"test-wt-4","session_id":"test-wt-004","cwd":"/tmp"}' > "$WDIR/test-wt-004.meta"
cat > "$WDIR/test-wt-004.events.jsonl" <<'JSON'
{"ts":"t0","event":"session_start","cwd":"/tmp"}
{"ts":"t1","event":"stop"}
JSON
EC=0
OUT=$(bash "$CSD" --worker test-wt-4 wait-for-turn 2 --after-line 2 2>/dev/null) || EC=$?
[ "$EC" = "1" ] && pass "--after-line 2 skips existing stop" || fail "after-line" "exit $EC, out $OUT"

# Append a fresh stop, --after-line 2 should match it
echo '{"ts":"t2","event":"stop"}' >> "$WDIR/test-wt-004.events.jsonl"
OUT=$(bash "$CSD" --worker test-wt-4 wait-for-turn 5 --after-line 2)
TS=$(echo "$OUT" | jq -r '.ts')
[ "$TS" = "t2" ] && pass "--after-line finds new stop" || fail "fresh stop" "got ts=$TS"

# --- timeout on no event ---
echo '{"tmux_name":"test-wt-5","session_id":"test-wt-005","cwd":"/tmp"}' > "$WDIR/test-wt-005.meta"
echo '{"ts":"t0","event":"session_start","cwd":"/tmp"}' > "$WDIR/test-wt-005.events.jsonl"
EC=0
bash "$CSD" --worker test-wt-5 wait-for-turn 2 >/dev/null 2>&1 || EC=$?
[ "$EC" = "1" ] && pass "exit 1 on timeout" || fail "timeout exit" "got $EC"

TOTAL=$((PASS_COUNT + FAIL_COUNT))
echo ""
echo "Results: $PASS_COUNT/$TOTAL passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
