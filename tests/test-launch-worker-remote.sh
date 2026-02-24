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

# Mock ssh: logs args, then dispatches subcommands so that transport_exec
# SSH calls work as expected. The remote command arrives as a single quoted
# string (from transport_exec's printf '%q' quoting + "${args[*]}" join):
#   tmux has-session  → exit 1 (no session)
#   tmux new-session  → run claude in background, exit 0
#   tmux send-keys / kill-session → exit 0
#   cat /path         → read local file (events file is local in tests)
#   other commands    → run locally via eval
cat > "$TMPDIR_TEST/bin/ssh" <<MOCK
#!/usr/bin/env bash
echo "\$@" >> "$TMPDIR_TEST/ssh.log"
# Skip SSH option flags to find the host index
ARGS=("\$@")
IDX=0
while [ \$IDX -lt \${#ARGS[@]} ]; do
  case "\${ARGS[\$IDX]}" in
    -o|-l|-p|-i|-F) IDX=\$((IDX+2)) ;;
    -tt|-T|-n|-q|-v|-4|-6) IDX=\$((IDX+1)) ;;
    *) break ;;
  esac
done
# Everything after the host is the remote command. With transport_exec's
# printf '%q' quoting, this arrives as a single string (real SSH passes
# args joined with spaces to the remote shell).
REMOTE="\${ARGS[*]:\$((IDX+1))}"
# Dispatch based on the command string
case "\$REMOTE" in
  "tmux has-session"*)
    exit 1
    ;;
  "tmux new-session"*)
    # Re-parse the quoted command string to extract the claude invocation
    eval "RCMD=(\$REMOTE)"
    TIDX=1  # skip "tmux"
    while [ \$TIDX -lt \${#RCMD[@]} ]; do
      case "\${RCMD[\$TIDX]}" in
        new-session) TIDX=\$((TIDX+1)) ;;
        -d)          TIDX=\$((TIDX+1)) ;;
        -s|-c|-e|-x|-y) TIDX=\$((TIDX+2)) ;;
        *) break ;;
      esac
    done
    CLAUDE_CMD=("\${RCMD[@]:\$TIDX}")
    if [ \${#CLAUDE_CMD[@]} -gt 0 ]; then
      "\${CLAUDE_CMD[@]}" &
    fi
    exit 0
    ;;
  "tmux"*)
    exit 0
    ;;
  *)
    # For cat, sh -c, mkdir, tail, etc. — run locally
    # (events file is on local fs in tests, so cat works)
    eval "\$REMOTE"
    exit \$?
    ;;
esac
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
  --target ssh://user@buildhost 2>/dev/null) || true
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
