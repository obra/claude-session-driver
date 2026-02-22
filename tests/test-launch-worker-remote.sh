#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAUNCH="$SCRIPT_DIR/../scripts/launch-worker.sh"
EVENT_DIR="/tmp/claude-workers"

PASS_COUNT=0; FAIL_COUNT=0
pass() { echo "  PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "  FAIL: $1 - $2"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

TMPDIR_TEST=$(mktemp -d)
cleanup() {
  rm -rf "$TMPDIR_TEST"
  rm -f "$EVENT_DIR"/test-launch-remote-*.{meta,events.jsonl}
}
trap cleanup EXIT
mkdir -p "$TMPDIR_TEST/bin" "$EVENT_DIR"

# Mock claude: reads --session-id arg, writes session_start event, exits
cat > "$TMPDIR_TEST/bin/claude" <<'MOCK'
#!/usr/bin/env bash
SESSION_ID=""
PREV=""
for arg in "$@"; do
  [ "$PREV" = "--session-id" ] && SESSION_ID="$arg"
  PREV="$arg"
done
mkdir -p /tmp/claude-workers
printf '{"ts":"2026-01-01T00:00:00Z","event":"session_start","cwd":"/tmp"}\n' \
  >> "/tmp/claude-workers/${SESSION_ID}.events.jsonl"
MOCK
chmod +x "$TMPDIR_TEST/bin/claude"

# Mock tmux:
#   has-session  → exit 1 (session does not exist, so launch proceeds)
#   new-session  → extract and run the claude command in background, exit 0
#   everything else → log and exit 0
cat > "$TMPDIR_TEST/bin/tmux" <<MOCK
#!/usr/bin/env bash
echo "\$@" >> "$TMPDIR_TEST/tmux.log"
case "\$1" in
  has-session)
    # Return 1 = session does not exist, so launch-worker proceeds
    exit 1
    ;;
  new-session)
    # Skip known tmux options to find the command to execute
    shift  # consume "new-session"
    CMD_ARGS=()
    while [ \$# -gt 0 ]; do
      case "\$1" in
        -d)             shift ;;
        -s|-c|-e|-x|-y) shift 2 ;;
        *) CMD_ARGS+=("\$@"); break ;;
      esac
    done
    if [ \${#CMD_ARGS[@]} -gt 0 ]; then
      "\${CMD_ARGS[@]}" &
    fi
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
MOCK
chmod +x "$TMPDIR_TEST/bin/tmux"

# Mock ssh: logs args, then dispatches tmux subcommands correctly so that
# transport_exec tmux calls through SSH work as expected:
#   tmux has-session  → exit 1 (no session)
#   tmux new-session  → run claude in background, exit 0
#   tmux send-keys / kill-session → exit 0
#   plain command (mkdir etc.) → exit 0
cat > "$TMPDIR_TEST/bin/ssh" <<MOCK
#!/usr/bin/env bash
# Log all args (skip ssh option flags so the log is readable)
echo "\$@" >> "$TMPDIR_TEST/ssh.log"
# Skip ssh options (-o key=val, -tt, etc.) to find host + command
ARGS=("\$@")
IDX=0
while [ \$IDX -lt \${#ARGS[@]} ]; do
  case "\${ARGS[\$IDX]}" in
    -o|-l|-p|-i|-F) IDX=\$((IDX+2)) ;;
    -tt|-T|-n|-q|-v|-4|-6) IDX=\$((IDX+1)) ;;
    *) break ;;
  esac
done
# ARGS[IDX] is the host, ARGS[IDX+1...] is the remote command
CMD_START=\$((IDX+1))
REMOTE_CMD=("\${ARGS[@]:\$CMD_START}")
# Check if remote command is a tmux invocation
if [ \${#REMOTE_CMD[@]} -gt 0 ] && [ "\${REMOTE_CMD[0]}" = "tmux" ]; then
  case "\${REMOTE_CMD[1]}" in
    has-session)
      exit 1
      ;;
    new-session)
      # Parse tmux new-session args to find the claude command
      TIDX=2  # skip "tmux new-session"
      while [ \$TIDX -lt \${#REMOTE_CMD[@]} ]; do
        case "\${REMOTE_CMD[\$TIDX]}" in
          -d) TIDX=\$((TIDX+1)) ;;
          -s|-c|-e|-x|-y) TIDX=\$((TIDX+2)) ;;
          *) break ;;
        esac
      done
      CLAUDE_CMD=("\${REMOTE_CMD[@]:\$TIDX}")
      if [ \${#CLAUDE_CMD[@]} -gt 0 ]; then
        "\${CLAUDE_CMD[@]}" &
      fi
      exit 0
      ;;
    send-keys|kill-session)
      exit 0
      ;;
  esac
fi
exit 0
MOCK
chmod +x "$TMPDIR_TEST/bin/ssh"

# Mock scp: logs args, succeeds
cat > "$TMPDIR_TEST/bin/scp" <<MOCK
#!/usr/bin/env bash
echo "\$@" >> "$TMPDIR_TEST/scp.log"
exit 0
MOCK
chmod +x "$TMPDIR_TEST/bin/scp"

# --- Test 1: --target local writes target=local to .meta ---
echo "Test 1: --target local writes target=local to .meta"
OUTPUT=$(PATH="$TMPDIR_TEST/bin:$PATH" bash "$LAUNCH" \
  --name test-launch-remote-001 --workdir /tmp --target local 2>/dev/null)
SESSION_ID=$(echo "$OUTPUT" | jq -r '.session_id' 2>/dev/null || true)

if [ -n "$SESSION_ID" ]; then
  TARGET_VAL=$(jq -r '.target' "$EVENT_DIR/${SESSION_ID}.meta" 2>/dev/null || true)
  CONTAINER_MANAGED=$(jq -r '.container_managed' "$EVENT_DIR/${SESSION_ID}.meta" 2>/dev/null || true)
  if [ "$TARGET_VAL" = "local" ] && [ "$CONTAINER_MANAGED" = "false" ]; then
    pass "--target local writes target=local and container_managed=false to .meta"
  else
    fail "--target local meta" "target=$TARGET_VAL container_managed=$CONTAINER_MANAGED"
  fi
else
  fail "--target local" "no session_id in output: $OUTPUT"
fi

# Reset logs
rm -f "$TMPDIR_TEST/tmux.log" "$TMPDIR_TEST/ssh.log" "$TMPDIR_TEST/scp.log"

# --- Test 2: --target ssh://user@buildhost writes correct target to .meta ---
echo "Test 2: --target ssh://user@buildhost writes target to .meta"
OUTPUT=$(PATH="$TMPDIR_TEST/bin:$PATH" bash "$LAUNCH" \
  --name test-launch-remote-002 --workdir /tmp \
  --target ssh://user@buildhost 2>/dev/null)
SESSION_ID=$(echo "$OUTPUT" | jq -r '.session_id' 2>/dev/null || true)

if [ -n "$SESSION_ID" ]; then
  TARGET_VAL=$(jq -r '.target' "$EVENT_DIR/${SESSION_ID}.meta" 2>/dev/null || true)
  if [ "$TARGET_VAL" = "ssh://user@buildhost" ]; then
    pass "--target ssh writes ssh://user@buildhost to .meta"
  else
    fail "--target ssh meta" "expected ssh://user@buildhost, got: $TARGET_VAL"
  fi
else
  fail "--target ssh" "no session_id in output: $OUTPUT"
fi

# --- Test 3: --target ssh:// calls scp to sync hooks ---
echo "Test 3: --target ssh:// calls scp for hook sync"
if grep -q "buildhost" "$TMPDIR_TEST/scp.log" 2>/dev/null; then
  pass "scp called with buildhost for hook sync"
else
  fail "hook sync scp" "scp.log: $(cat "$TMPDIR_TEST/scp.log" 2>/dev/null || echo empty)"
fi

# --- Summary ---
echo ""
TOTAL=$((PASS_COUNT + FAIL_COUNT))
echo "Results: $PASS_COUNT/$TOTAL passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -gt 0 ] && exit 1 || exit 0
