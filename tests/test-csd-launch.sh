#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CSD="$SCRIPT_DIR/../skills/driving-claude-code-sessions/scripts/csd"
WDIR=/tmp/csd-workers

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "  PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "  FAIL: $1 - $2"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

TMUX_NAME="test-csd-launch-$$"
FAKE_HOME=$(mktemp -d)
cleanup() {
  tmux kill-session -t "$TMUX_NAME" 2>/dev/null || true
  rm -rf "$FAKE_HOME"
  rm -f "$WDIR"/*-test-launch-*.meta
  rm -f "$WDIR/bin/$TMUX_NAME"
}
trap cleanup EXIT
cleanup
mkdir -p "$WDIR" "$WDIR/bin" "$FAKE_HOME/.claude"
touch "$FAKE_HOME/.claude/.claude-session-driver-consent"

# Use the harness's existing fake-claude trick: launch points at a /bin/sh that
# emits session_start by writing to /tmp/csd-workers/<sid>.events.jsonl.
# We need the session_id, so we wrap a tiny helper that the test injects via
# the test-mode flag --test-claude-cmd.

# Simpler approach: skip the real claude. Provide a fake CLAUDE_BIN env var
# that csd respects when set, pointing at a stub that writes session_start.
FAKE_CLAUDE=$(mktemp)
cat > "$FAKE_CLAUDE" <<'BASH'
#!/bin/bash
# Stub claude that writes a session_start event keyed off --session-id.
SID=""
while [ $# -gt 0 ]; do
  case "$1" in
    --session-id) SID="$2"; shift 2 ;;
    *) shift ;;
  esac
done
mkdir -p /tmp/csd-workers
echo "{\"ts\":\"$(date -u +%FT%TZ)\",\"event\":\"session_start\",\"cwd\":\"$PWD\"}" \
  > "/tmp/csd-workers/${SID}.events.jsonl"
# Stay alive so tmux session persists
exec sleep 60
BASH
chmod +x "$FAKE_CLAUDE"

OUTPUT=$(CSD_CLAUDE_BIN="$FAKE_CLAUDE" HOME="$FAKE_HOME" \
         bash "$CSD" launch "$TMUX_NAME" /tmp -- --model sonnet 2>/tmp/launch-stderr-$$)
STDERR=$(cat /tmp/launch-stderr-$$ || true); rm -f /tmp/launch-stderr-$$
EXPECTED_SHIM="/tmp/csd-workers/bin/$TMUX_NAME"

# stdout is exactly the shim path
if [ "$OUTPUT" = "$EXPECTED_SHIM" ]; then
  pass "stdout is the shim path"
else
  fail "stdout" "expected '$EXPECTED_SHIM', got '$OUTPUT'"
fi

# shim file exists and is executable
if [ -x "$EXPECTED_SHIM" ]; then
  pass "shim is executable"
else
  fail "shim exec" "$EXPECTED_SHIM not executable"
fi

# shim execs into csd with --worker baked in
SHIM_BODY=$(cat "$EXPECTED_SHIM")
if echo "$SHIM_BODY" | grep -q "exec.*csd.*--worker \"$TMUX_NAME\""; then
  pass "shim execs csd with --worker"
else
  fail "shim body" "$SHIM_BODY"
fi

# stderr contains reproduce line with the full invocation
if echo "$STDERR" | grep -q "reproduce:.*launch $TMUX_NAME /tmp -- --model sonnet"; then
  pass "stderr has reproduce line"
else
  fail "reproduce" "$STDERR"
fi

# stderr panel includes the worker's cwd
if echo "$STDERR" | grep -qE "^\s*cwd:\s+/(private/)?tmp$"; then
  pass "stderr panel includes cwd"
else
  fail "cwd line" "$STDERR"
fi

# meta file has cwd and invocation fields
META=$(ls "$WDIR"/*.meta | xargs grep -l "$TMUX_NAME" | head -1)
if jq -e '.cwd' "$META" >/dev/null; then
  pass "meta has cwd"
else
  fail "meta cwd" "$(cat "$META")"
fi
if jq -e '.invocation' "$META" >/dev/null; then
  pass "meta has invocation"
else
  fail "meta invocation" "$(cat "$META")"
fi

# Running the shim should dispatch into csd: session-id returns the worker's id
SID_VIA_SHIM=$("$EXPECTED_SHIM" session-id)
SID_IN_META=$(jq -r '.session_id' "$META")
[ "$SID_VIA_SHIM" = "$SID_IN_META" ] && pass "shim routes to the right worker" || fail "shim routing" "$SID_VIA_SHIM vs $SID_IN_META"

# Collision: second launch with same tmux name should fail
EC=0
CSD_CLAUDE_BIN="$FAKE_CLAUDE" HOME="$FAKE_HOME" \
  bash "$CSD" launch "$TMUX_NAME" /tmp 2>/dev/null >/dev/null || EC=$?
[ "$EC" -ne 0 ] && pass "collision rejected" || fail "collision" "exit 0"

TOTAL=$((PASS_COUNT + FAIL_COUNT))
echo ""
echo "Results: $PASS_COUNT/$TOTAL passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
