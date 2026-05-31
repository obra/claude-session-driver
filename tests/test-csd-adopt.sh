#!/bin/bash
set -euo pipefail

# Tests for `csd adopt` — re-adopting an existing Claude session (by id) as a
# driveable worker via `claude --resume`. Covers: stdout/shim contract, meta
# keyed by the *given* session id, the new-pane path, the respawn-existing-pane
# path (simulating a tmux-resurrect restore), and session-id validation.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CSD="$SCRIPT_DIR/../skills/driving-claude-code-sessions/scripts/csd"
WDIR=/tmp/claude-workers

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "  PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "  FAIL: $1 - ${2:-}"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

TMUX_NEW="test-csd-adopt-new-$$"
TMUX_RESPAWN="test-csd-adopt-respawn-$$"
SID_NEW=$(uuidgen | tr '[:upper:]' '[:lower:]')
SID_RESPAWN=$(uuidgen | tr '[:upper:]' '[:lower:]')
FAKE_HOME=$(mktemp -d)
FAKE_CLAUDE=$(mktemp)

cleanup() {
  tmux kill-session -t "$TMUX_NEW" 2>/dev/null || true
  tmux kill-session -t "$TMUX_RESPAWN" 2>/dev/null || true
  rm -rf "$FAKE_HOME"
  rm -f "$FAKE_CLAUDE"
  rm -f "$WDIR/$SID_NEW".* "$WDIR/$SID_RESPAWN".*
  rm -f "$WDIR/bin/$TMUX_NEW" "$WDIR/bin/$TMUX_RESPAWN"
}
trap cleanup EXIT
cleanup
mkdir -p "$WDIR" "$WDIR/bin" "$FAKE_HOME/.claude"
touch "$FAKE_HOME/.claude/.claude-session-driver-consent"

# Stub claude that writes a session_start event keyed off --resume (adopt uses
# --resume, not --session-id). Mirrors the fake-claude trick in test-csd-launch.
cat > "$FAKE_CLAUDE" <<'BASH'
#!/bin/bash
SID=""
while [ $# -gt 0 ]; do
  case "$1" in
    --resume) SID="$2"; shift 2 ;;
    *) shift ;;
  esac
done
mkdir -p /tmp/claude-workers
echo "{\"ts\":\"$(date -u +%FT%TZ)\",\"event\":\"session_start\",\"cwd\":\"$PWD\"}" \
  > "/tmp/claude-workers/${SID}.events.jsonl"
exec sleep 60
BASH
chmod +x "$FAKE_CLAUDE"

# ---- 1. New-pane path (no pre-existing tmux session) ----------------------
OUT=$(CSD_CLAUDE_BIN="$FAKE_CLAUDE" HOME="$FAKE_HOME" \
      bash "$CSD" adopt "$TMUX_NEW" /tmp "$SID_NEW" -- --model sonnet 2>/tmp/adopt-err-$$)
ERR=$(cat /tmp/adopt-err-$$ || true); rm -f /tmp/adopt-err-$$
SHIM="$WDIR/bin/$TMUX_NEW"

[ "$OUT" = "$SHIM" ] && pass "stdout is the shim path" || fail "stdout" "expected '$SHIM', got '$OUT'"
[ -x "$SHIM" ] && pass "shim is executable" || fail "shim exec" "$SHIM"
grep -q "exec.*csd.*--worker \"$TMUX_NEW\"" "$SHIM" && pass "shim execs csd with --worker" || fail "shim body" "$(cat "$SHIM")"

# meta is keyed by the GIVEN session id (the whole point: resume preserves it)
if [ -f "$WDIR/$SID_NEW.meta" ]; then
  pass "meta is keyed by the given session id"
else
  fail "meta key" "$WDIR/$SID_NEW.meta missing"
fi
META_SID=$(jq -r '.session_id' "$WDIR/$SID_NEW.meta" 2>/dev/null || echo "")
[ "$META_SID" = "$SID_NEW" ] && pass "meta.session_id == given id" || fail "meta sid" "$META_SID vs $SID_NEW"

# worker is live: session_start recorded
grep -q '"event":"session_start"' "$WDIR/$SID_NEW.events.jsonl" 2>/dev/null \
  && pass "session_start recorded (worker live)" || fail "session_start" "no event"

# reproduce + panel say adopt, not launch
echo "$ERR" | grep -q "Worker adopted (opened new pane)" && pass "panel: opened new pane" || fail "panel mode" "$ERR"
echo "$ERR" | grep -q "reproduce:.*adopt $TMUX_NEW /tmp $SID_NEW -- --model sonnet" \
  && pass "reproduce line says adopt" || fail "reproduce" "$ERR"

# shim routes to the right worker
SID_VIA_SHIM=$("$SHIM" session-id 2>/dev/null || echo "")
[ "$SID_VIA_SHIM" = "$SID_NEW" ] && pass "shim routes to the right worker" || fail "shim routing" "$SID_VIA_SHIM vs $SID_NEW"

# ---- 2. Respawn-existing-pane path (simulate a tmux-resurrect restore) -----
# Pre-create a session with a dead-ish command, as continuum would on restore.
tmux new-session -d -s "$TMUX_RESPAWN" "sleep 300"
OUT2=$(CSD_CLAUDE_BIN="$FAKE_CLAUDE" HOME="$FAKE_HOME" \
       bash "$CSD" adopt "$TMUX_RESPAWN" /tmp "$SID_RESPAWN" 2>/tmp/adopt-err2-$$)
ERR2=$(cat /tmp/adopt-err2-$$ || true); rm -f /tmp/adopt-err2-$$

echo "$ERR2" | grep -q "Worker adopted (respawned existing pane)" \
  && pass "respawns the pre-existing (restored) pane in place" || fail "respawn mode" "$ERR2"
grep -q '"event":"session_start"' "$WDIR/$SID_RESPAWN.events.jsonl" 2>/dev/null \
  && pass "respawned worker is live" || fail "respawn live" "no event"
# the session name (and thus restored layout) is preserved, not recreated
tmux has-session -t "$TMUX_RESPAWN" 2>/dev/null \
  && pass "original session name preserved" || fail "session gone" "$TMUX_RESPAWN"

# ---- 3. Validation: a non-uuid session id (e.g. a path) is rejected --------
EC=0
CSD_CLAUDE_BIN="$FAKE_CLAUDE" HOME="$FAKE_HOME" \
  bash "$CSD" adopt bogus-name /tmp "/tmp/not/a/session" 2>/dev/null >/dev/null || EC=$?
[ "$EC" -ne 0 ] && pass "rejects a non-uuid session id" || fail "validation" "exit 0"

# ---- 4. Consent is required ------------------------------------------------
EC=0
NOCONSENT=$(mktemp -d)
CSD_CLAUDE_BIN="$FAKE_CLAUDE" HOME="$NOCONSENT" \
  bash "$CSD" adopt bogus2 /tmp "$(uuidgen)" 2>/dev/null >/dev/null || EC=$?
rm -rf "$NOCONSENT"
[ "$EC" -ne 0 ] && pass "requires consent" || fail "consent" "exit 0"

TOTAL=$((PASS_COUNT + FAIL_COUNT))
echo ""
echo "Results: $PASS_COUNT/$TOTAL passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
