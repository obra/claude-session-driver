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
  rm -f "$WDIR/test-handoff-001.meta"
}
trap cleanup EXIT
cleanup
mkdir -p "$WDIR"

echo '{"tmux_name":"test-handoff","session_id":"test-handoff-001","cwd":"/tmp"}' > "$WDIR/test-handoff-001.meta"

OUTPUT=$(bash "$CSD" --worker test-handoff handoff)
echo "$OUTPUT" | grep -q "tmux attach -t test-handoff" && pass "includes attach command" || fail "attach" "$OUTPUT"
echo "$OUTPUT" | grep -qi "ctrl-b d" && pass "includes detach instructions" || fail "detach" "$OUTPUT"

TOTAL=$((PASS_COUNT + FAIL_COUNT))
echo ""
echo "Results: $PASS_COUNT/$TOTAL passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
