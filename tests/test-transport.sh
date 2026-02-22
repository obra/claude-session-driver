#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TRANSPORT="$SCRIPT_DIR/../lib/transport.sh"

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "  PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "  FAIL: $1 - $2"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

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
trap 'rm -f "$META_FILE"; rm -rf "$TMPDIR_TEST"' EXIT
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

# --- Summary ---
echo ""
TOTAL=$((PASS_COUNT + FAIL_COUNT))
echo "Results: $PASS_COUNT/$TOTAL passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -gt 0 ] && exit 1 || exit 0
