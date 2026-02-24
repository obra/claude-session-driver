#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WAIT="$SCRIPT_DIR/../scripts/wait-for-event.sh"
EVENT_DIR="/tmp/claude-workers"

PASS_COUNT=0; FAIL_COUNT=0
pass() { echo "  PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "  FAIL: $1 - $2"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

TMPDIR_TEST=$(mktemp -d)
cleanup() {
  rm -rf "$TMPDIR_TEST"
  rm -f "$EVENT_DIR"/test-wait-remote-{001,002}.{meta,events.jsonl}
}
trap cleanup EXIT
mkdir -p "$TMPDIR_TEST/bin" "$EVENT_DIR"

# Test 1: local target finds event
echo "Test 1: local target finds stop event"
SESSION_ID="test-wait-remote-001"
echo '{"session_id":"'$SESSION_ID'","target":"local","cwd":"/tmp"}' \
  > "$EVENT_DIR/${SESSION_ID}.meta"
echo '{"ts":"2026-01-01T00:00:00Z","event":"stop"}' \
  > "$EVENT_DIR/${SESSION_ID}.events.jsonl"
RESULT=$(bash "$WAIT" "$SESSION_ID" stop 5)
echo "$RESULT" | jq -e '.event == "stop"' > /dev/null \
  && pass "local target finds stop event" \
  || fail "local target" "wrong result: $RESULT"

# Test 2: ssh target streams events via ssh
echo "Test 2: ssh target reads events via ssh"
SESSION_ID2="test-wait-remote-002"
echo '{"session_id":"'$SESSION_ID2'","target":"ssh://user@host","cwd":"/tmp"}' \
  > "$EVENT_DIR/${SESSION_ID2}.meta"
# Mock ssh: prints a stop event and exits
cat > "$TMPDIR_TEST/bin/ssh" <<'MOCK'
#!/usr/bin/env bash
echo '{"ts":"2026-01-01T00:00:00Z","event":"stop"}'
MOCK
chmod +x "$TMPDIR_TEST/bin/ssh"
RESULT=$(PATH="$TMPDIR_TEST/bin:$PATH" bash "$WAIT" "$SESSION_ID2" stop 5)
echo "$RESULT" | jq -e '.event == "stop"' > /dev/null \
  && pass "ssh target reads event via ssh" \
  || fail "ssh target" "wrong result: $RESULT"

echo ""
TOTAL=$((PASS_COUNT + FAIL_COUNT))
echo "Results: $PASS_COUNT/$TOTAL passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -gt 0 ] && exit 1 || exit 0
