#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CSD="$SCRIPT_DIR/../skills/driving-claude-code-sessions/scripts/csd"
WDIR=/tmp/claude-workers

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "  PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "  FAIL: $1 - $2"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

TMUX_NAME="test-csd-stop"
SID="test-stop-001"
cleanup() {
  tmux kill-session -t "$TMUX_NAME" 2>/dev/null || true
  rm -f "$WDIR/$SID.meta" "$WDIR/$SID.events.jsonl" "$WDIR/bin/$TMUX_NAME"
}
trap cleanup EXIT
cleanup
mkdir -p "$WDIR" "$WDIR/bin"

# Set up a worker: tmux session, meta, events, shim
tmux new-session -d -s "$TMUX_NAME" 'sleep 60'
echo "{\"tmux_name\":\"$TMUX_NAME\",\"session_id\":\"$SID\",\"cwd\":\"/tmp\"}" > "$WDIR/$SID.meta"
echo '{"event":"stop"}' > "$WDIR/$SID.events.jsonl"
echo '#!/bin/bash' > "$WDIR/bin/$TMUX_NAME"
chmod +x "$WDIR/bin/$TMUX_NAME"

STOP_OUTPUT=$(bash "$CSD" --worker "$TMUX_NAME" stop)

tmux has-session -t "$TMUX_NAME" 2>/dev/null && fail "tmux still alive" "$(tmux ls)" || pass "tmux killed"
[ ! -f "$WDIR/$SID.meta" ] && pass "meta removed" || fail "meta" "still present"
[ ! -f "$WDIR/$SID.events.jsonl" ] && pass "events removed" || fail "events" "still present"
[ ! -f "$WDIR/bin/$TMUX_NAME" ] && pass "shim removed" || fail "shim" "still present"
echo "$STOP_OUTPUT" | grep -qi "shim removed" && pass "output mentions shim removed" || fail "output" "expected 'Shim removed' in: $STOP_OUTPUT"

TOTAL=$((PASS_COUNT + FAIL_COUNT))
echo ""
echo "Results: $PASS_COUNT/$TOTAL passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
