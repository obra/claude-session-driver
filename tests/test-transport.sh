#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TRANSPORT="$SCRIPT_DIR/../lib/transport.sh"

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "  PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "  FAIL: $1 - $2"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

TMPDIR_TEST=$(mktemp -d)

cleanup() {
  rm -rf "$TMPDIR_TEST"
  rm -f /tmp/claude-workers/test-transport-{004,005}.meta
}
trap cleanup EXIT

# --- Test 1: transport_exec local runs command directly ---
echo "Test 1: transport_exec local runs command"
(
  WORKER_TARGET=local
  source "$TRANSPORT"
  RESULT=$(transport_exec echo "hello-local")
  if [ "$RESULT" = "hello-local" ]; then
    echo "PASS"
  else
    echo "FAIL:$RESULT"
  fi
) | grep -q "^PASS" && pass "transport_exec local runs command" || fail "transport_exec local" "did not run"

# --- Test 2: transport_read local reads file ---
echo "Test 2: transport_read local reads file"
echo "file-content" > "$TMPDIR_TEST/test.txt"
(
  WORKER_TARGET=local
  source "$TRANSPORT"
  transport_read "$TMPDIR_TEST/test.txt"
) | grep -q "file-content" && pass "transport_read local reads file" || fail "transport_read local" "wrong content"

# --- Test 3: transport_write local writes file ---
echo "Test 3: transport_write local writes file"
(
  WORKER_TARGET=local
  source "$TRANSPORT"
  transport_write '{"decision":"allow"}' "$TMPDIR_TEST/written.txt"
)
if [ -f "$TMPDIR_TEST/written.txt" ] && grep -q "allow" "$TMPDIR_TEST/written.txt"; then
  pass "transport_write local writes file"
else
  fail "transport_write local" "file not written or wrong content"
fi

# --- Test 4: csd_load_target reads target from .meta ---
echo "Test 4: csd_load_target reads target from .meta"
mkdir -p /tmp/claude-workers
SESSION_ID="test-transport-004"
META_FILE="/tmp/claude-workers/${SESSION_ID}.meta"
echo '{"session_id":"test-transport-004","target":"ssh://user@remotehost","cwd":"/tmp"}' > "$META_FILE"
(
  source "$TRANSPORT"
  csd_load_target "test-transport-004"
  echo "$WORKER_TARGET"
) | grep -q "ssh://user@remotehost" && pass "csd_load_target reads target from .meta" || fail "csd_load_target" "wrong target"

# --- Test 5: csd_load_target defaults to local when field absent ---
echo "Test 5: csd_load_target defaults to local when target field absent"
echo '{"session_id":"test-transport-005","cwd":"/tmp"}' > /tmp/claude-workers/test-transport-005.meta
(
  source "$TRANSPORT"
  csd_load_target "test-transport-005"
  echo "${WORKER_TARGET:-local}"
) | grep -q "local" && pass "csd_load_target defaults to local" || fail "csd_load_target default" "not local"

# --- Test 6: unknown target returns error ---
echo "Test 6: unknown target returns error"
(
  WORKER_TARGET="bogus://x"
  source "$TRANSPORT"
  transport_exec echo "should not run"
) 2>/dev/null && fail "unknown target" "should have failed" || pass "transport_exec unknown target returns error"

# Helper: create a mock command that logs its args to a file
make_mock() {
  local name="$1"
  local log="$2"
  local output="${3:-}"
  cat > "$TMPDIR_TEST/bin/$name" <<MOCK
#!/usr/bin/env bash
echo "\$@" >> "$log"
${output:+echo "$output"}
MOCK
  chmod +x "$TMPDIR_TEST/bin/$name"
}

mkdir -p "$TMPDIR_TEST/bin"

# --- Test 7: transport_exec ssh:// calls ssh with host and command ---
echo "Test 7: transport_exec ssh:// calls ssh with correct args"
SSH_LOG="$TMPDIR_TEST/ssh7.log"
make_mock ssh "$SSH_LOG"
(
  export PATH="$TMPDIR_TEST/bin:$PATH"
  WORKER_TARGET="ssh://user@buildhost"
  source "$TRANSPORT"
  transport_exec tmux new-session -d -s myworker
)
if grep -q "user@buildhost" "$SSH_LOG" && grep -q "tmux" "$SSH_LOG"; then
  pass "transport_exec ssh calls ssh with host and tmux command"
else
  fail "transport_exec ssh" "wrong ssh call: $(cat "$SSH_LOG" 2>/dev/null || echo empty)"
fi

# --- Test 8: transport_read ssh:// calls ssh with cat ---
echo "Test 8: transport_read ssh:// calls ssh with cat"
SSH_LOG8="$TMPDIR_TEST/ssh8.log"
make_mock ssh "$SSH_LOG8" "remote-file-content"
RESULT=$(
  export PATH="$TMPDIR_TEST/bin:$PATH"
  WORKER_TARGET="ssh://user@buildhost"
  source "$TRANSPORT"
  transport_read /tmp/some/file.jsonl
)
if echo "$RESULT" | grep -q "remote-file-content"; then
  pass "transport_read ssh returns output"
else
  fail "transport_read ssh" "wrong output: $RESULT"
fi

# --- Test 9: transport_write ssh:// pipes content via ssh ---
echo "Test 9: transport_write ssh:// pipes content via ssh"
SSH_LOG9="$TMPDIR_TEST/ssh9.log"
make_mock ssh "$SSH_LOG9"
(
  export PATH="$TMPDIR_TEST/bin:$PATH"
  WORKER_TARGET="ssh://user@buildhost"
  source "$TRANSPORT"
  transport_write '{"decision":"allow"}' "/tmp/test.decision"
)
grep -q "user@buildhost" "$SSH_LOG9" \
  && pass "transport_write ssh calls ssh" \
  || fail "transport_write ssh" "ssh not called: $(cat "$SSH_LOG9" 2>/dev/null || echo empty)"

# --- Test 10: transport_exec docker:// calls docker exec ---
echo "Test 10: transport_exec docker:// calls docker exec"
DOCKER_LOG10="$TMPDIR_TEST/docker10.log"
make_mock docker "$DOCKER_LOG10"
(
  export PATH="$TMPDIR_TEST/bin:$PATH"
  WORKER_TARGET="docker://my-container"
  source "$TRANSPORT"
  transport_exec tmux list-sessions
)
if grep -q "my-container" "$DOCKER_LOG10" && grep -q "tmux" "$DOCKER_LOG10"; then
  pass "transport_exec docker calls docker exec with container"
else
  fail "transport_exec docker" "wrong docker call: $(cat "$DOCKER_LOG10" 2>/dev/null || echo empty)"
fi

# --- Test 11: transport_write docker:// uses docker exec -i ---
echo "Test 11: transport_write docker:// uses docker exec -i"
DOCKER_LOG11="$TMPDIR_TEST/docker11.log"
make_mock docker "$DOCKER_LOG11"
(
  export PATH="$TMPDIR_TEST/bin:$PATH"
  WORKER_TARGET="docker://my-container"
  source "$TRANSPORT"
  transport_write '{"decision":"deny"}' "/tmp/test.decision"
)
grep -q "my-container" "$DOCKER_LOG11" \
  && pass "transport_write docker calls docker exec -i" \
  || fail "transport_write docker" "wrong docker call: $(cat "$DOCKER_LOG11" 2>/dev/null || echo empty)"

# --- Summary ---
echo ""
TOTAL=$((PASS_COUNT + FAIL_COUNT))
echo "Results: $PASS_COUNT/$TOTAL passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -gt 0 ] && exit 1 || exit 0
