#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SEND_PROMPT="$SCRIPT_DIR/../scripts/send-prompt.sh"

PASS_COUNT=0; FAIL_COUNT=0
pass() { echo "  PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "  FAIL: $1 - $2"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

TMPDIR_TEST=$(mktemp -d)
cleanup() {
  rm -rf "$TMPDIR_TEST"
  rm -f /tmp/claude-workers/test-sp-{001,002}.meta
}
trap cleanup EXIT
mkdir -p "$TMPDIR_TEST/bin" /tmp/claude-workers

make_mock() {
  local name="$1"; local log="$2"; local exit_code="${3:-0}"
  cat > "$TMPDIR_TEST/bin/$name" <<MOCK
#!/usr/bin/env bash
echo "\$@" >> "$log"
exit $exit_code
MOCK
  chmod +x "$TMPDIR_TEST/bin/$name"
}

# Test 1: local target uses tmux directly
echo "Test 1: local target calls tmux send-keys"
echo '{"tmux_name":"sp-local","session_id":"test-sp-001","target":"local","cwd":"/tmp"}' \
  > /tmp/claude-workers/test-sp-001.meta
TMUX_LOG="$TMPDIR_TEST/tmux1.log"
make_mock tmux "$TMUX_LOG"
PATH="$TMPDIR_TEST/bin:$PATH" bash "$SEND_PROMPT" sp-local test-sp-001 "hello world" 2>/dev/null || true
grep -q "send-keys" "$TMUX_LOG" && grep -q "hello world" "$TMUX_LOG" \
  && pass "local send-prompt calls tmux send-keys" \
  || fail "local send-prompt" "tmux not called correctly: $(cat "$TMUX_LOG" 2>/dev/null)"

# Test 2: ssh target calls ssh with tmux send-keys
echo "Test 2: ssh target calls ssh with tmux send-keys"
echo '{"tmux_name":"sp-remote","session_id":"test-sp-002","target":"ssh://user@host","cwd":"/tmp"}' \
  > /tmp/claude-workers/test-sp-002.meta
SSH_LOG="$TMPDIR_TEST/ssh2.log"
make_mock ssh "$SSH_LOG"
PATH="$TMPDIR_TEST/bin:$PATH" bash "$SEND_PROMPT" sp-remote test-sp-002 "remote prompt" 2>/dev/null || true
grep -q "user@host" "$SSH_LOG" && grep -q "send-keys" "$SSH_LOG" \
  && pass "ssh target send-prompt calls ssh with tmux" \
  || fail "ssh send-prompt" "wrong call: $(cat "$SSH_LOG" 2>/dev/null)"

echo ""
TOTAL=$((PASS_COUNT + FAIL_COUNT))
echo "Results: $PASS_COUNT/$TOTAL passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -gt 0 ] && exit 1 || exit 0
