#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CSD="$SCRIPT_DIR/../skills/driving-claude-code-sessions/scripts/csd"

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "  PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "  FAIL: $1 - $2"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

TMUX_NAME="test-csd-int-$$"
FAKE_HOME=$(mktemp -d)
FAKE_HOME=$(cd "$FAKE_HOME" && pwd -P)
mkdir -p "$FAKE_HOME/.claude"
touch "$FAKE_HOME/.claude/.claude-session-driver-consent"

cleanup() {
  tmux kill-session -t "$TMUX_NAME" 2>/dev/null || true
  rm -f /tmp/claude-workers/bin/"$TMUX_NAME"
  for f in /tmp/claude-workers/*.meta; do
    [ -f "$f" ] || continue
    if jq -e --arg n "$TMUX_NAME" '.tmux_name == $n' "$f" >/dev/null 2>&1; then
      sid=$(jq -r '.session_id' "$f")
      rm -f "$f" "/tmp/claude-workers/${sid}.events.jsonl"
    fi
  done
}
trap cleanup EXIT
cleanup

FAKE_CLAUDE=$(mktemp)
cat > "$FAKE_CLAUDE" <<'BASH'
#!/bin/bash
SID=""
while [ $# -gt 0 ]; do
  case "$1" in
    --session-id) SID="$2"; shift 2 ;;
    *) shift ;;
  esac
done
mkdir -p /tmp/claude-workers
echo "{\"ts\":\"$(date -u +%FT%TZ)\",\"event\":\"session_start\",\"cwd\":\"$PWD\"}" \
  > "/tmp/claude-workers/${SID}.events.jsonl"
exec sleep 60
BASH
chmod +x "$FAKE_CLAUDE"

SHIM=$(CSD_CLAUDE_BIN="$FAKE_CLAUDE" HOME="$FAKE_HOME" \
       bash "$CSD" launch "$TMUX_NAME" /tmp 2>/dev/null)
[ -x "$SHIM" ] && pass "launch returned executable shim" || fail "shim" "not executable: $SHIM"

# status via shim
STATUS=$("$SHIM" status)
[ "$STATUS" = "idle" ] && pass "shim status = idle" || fail "status" "got $STATUS"

# session-id via shim matches meta
SID_VIA_SHIM=$("$SHIM" session-id)
META=$(ls /tmp/claude-workers/*.meta | xargs grep -l "$TMUX_NAME" | head -1)
SID_IN_META=$(jq -r '.session_id' "$META")
[ "$SID_VIA_SHIM" = "$SID_IN_META" ] && pass "session-id matches" || fail "sid" "shim=$SID_VIA_SHIM meta=$SID_IN_META"

# read-events via shim
EVENTS=$("$SHIM" read-events)
echo "$EVENTS" | grep -q session_start && pass "read-events returns session_start" || fail "read-events" "$EVENTS"

# stop via shim removes everything
"$SHIM" stop >/dev/null
[ ! -f "$SHIM" ] && pass "stop removed shim" || fail "shim cleanup" "still present"
[ ! -f "$META" ] && pass "stop removed meta" || fail "meta cleanup" "still present"

TOTAL=$((PASS_COUNT + FAIL_COUNT))
echo ""
echo "Results: $PASS_COUNT/$TOTAL passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
