#!/bin/bash
# Tests for scripts/launch-worker.sh
#
# Regression coverage for #11: when launched from inside another claude
# session, the worker inherits env vars (CLAUDECODE, etc.) that break the
# nested spawn. launch-worker.sh now runs claude through an inline bootstrap
# that explicitly `unset`s the leak vars, silences the bypass-permissions
# warning via `--settings`, and requires one-time consent via
# ~/.claude/.claude-session-driver-consent. The worker authenticates via
# ~/.claude.json the same way an interactive `claude` invocation does.
#
# Strategy: stand up a stub `claude` on PATH that dumps its argv + env to a
# file, run launch-worker.sh against it, inspect the dump.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPTS_DIR="$PLUGIN_DIR/skills/driving-claude-code-sessions/scripts"
LAUNCH_WORKER="$SCRIPTS_DIR/launch-worker.sh"

STUB_DIR=$(mktemp -d)
STUB_LOG="$STUB_DIR/claude.env.log"
# Use a temporary HOME so the consent dotfile lands in a sandbox we own.
TEST_HOME=$(mktemp -d)

# Track every tmux session we create and every worker session-id assigned to
# us, so cleanup can tear them all down regardless of which test variant ran.
TMUX_NAMES=()
LAUNCH_PIDS=()

FAILURES=0
TESTS=0

fail() { echo "FAIL: $1"; FAILURES=$((FAILURES+1)); }
pass() { echo "PASS: $1"; }
run_test() { TESTS=$((TESTS+1)); }

cleanup() {
  for pid in "${LAUNCH_PIDS[@]+"${LAUNCH_PIDS[@]}"}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  for name in "${TMUX_NAMES[@]+"${TMUX_NAMES[@]}"}"; do
    tmux kill-session -t "$name" 2>/dev/null || true
  done
  # Walk every meta file under /tmp/claude-workers/ and delete only those
  # whose tmux_name matches a session we created here. This avoids touching
  # any live worker the user may be running in parallel.
  if [ -d /tmp/claude-workers ] && [ "${#TMUX_NAMES[@]}" -gt 0 ]; then
    for meta in /tmp/claude-workers/*.meta; do
      [ -f "$meta" ] || continue
      local_tmux=$(jq -r '.tmux_name // ""' "$meta" 2>/dev/null || true)
      for our_name in "${TMUX_NAMES[@]+"${TMUX_NAMES[@]}"}"; do
        if [ "$local_tmux" = "$our_name" ]; then
          sid=$(jq -r '.session_id // ""' "$meta" 2>/dev/null || true)
          rm -f "$meta"
          [ -n "$sid" ] && rm -f "/tmp/claude-workers/${sid}.events.jsonl"
          break
        fi
      done
    done
  fi
  rm -rf "$STUB_DIR" "$TEST_HOME"
}
trap cleanup EXIT

# Pre-grant consent so we can exercise the launch path itself. The consent
# flow has its own dedicated test below.
mkdir -p "$TEST_HOME/.claude"
echo "Consent granted at $(date -u +%FT%TZ)" > "$TEST_HOME/.claude/.claude-session-driver-consent"

# Stub `claude` that dumps argv + env to STUB_LOG, then idles. After the
# bootstrap's `exec "$@"`, the stub runs as if it were claude itself.
cat > "$STUB_DIR/claude" <<STUB
#!/bin/bash
{
  echo "===ARGV==="
  printf '%s\n' "\$@"
  echo "===ENV==="
  env
} > "$STUB_LOG"
sleep 60
STUB
chmod +x "$STUB_DIR/claude"

run_stub_launch() {
  local tmux_name="$1"
  shift
  rm -f "$STUB_LOG"
  TMUX_NAMES+=("$tmux_name")
  HOME="$TEST_HOME" PATH="$STUB_DIR:$PATH" \
    bash "$LAUNCH_WORKER" "$tmux_name" /tmp "$@" >/dev/null 2>&1 &
  local pid=$!
  LAUNCH_PIDS+=("$pid")
  # Wait up to 5s for the stub to write its dump.
  for _ in $(seq 1 50); do
    [ -s "$STUB_LOG" ] && break
    sleep 0.1
  done
}

# --- Scenario A: controller has the leak vars set ---
# We only strip the two that actually break the worker (SSE_PORT and
# PROVIDER_MANAGED_BY_HOST). CLAUDECODE/ENTRYPOINT are deliberately not
# stripped — see launch-worker.sh comment.
export CLAUDE_CODE_SSE_PORT=12345
export CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST=1

run_stub_launch "launch-test-a-$$"

if [ ! -s "$STUB_LOG" ]; then
  fail "Stub claude was never invoked in scenario A (log empty after 5s)"
  echo "Results: $((TESTS - FAILURES))/$TESTS passed"
  exit 1
fi

ENV_DUMP=$(sed -n '/===ENV===/,$p' "$STUB_LOG" | tail -n +2)
ARGV_DUMP=$(sed -n '/===ARGV===/,/===ENV===/p' "$STUB_LOG" | sed '1d;$d')

# --- Test 1: SSE_PORT and PROVIDER_MANAGED_BY_HOST are blanked by tmux -e ---
# `tmux -e VAR=` sets the var to empty rather than removing it. Claude code
# uses truthy checks on both so empty is equivalent to unset for it; from
# our test perspective the assertion is "the leaked controller value is gone".
for var in CLAUDE_CODE_SSE_PORT CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST; do
  run_test
  LINE=$(echo "$ENV_DUMP" | grep -E "^${var}=" || true)
  if [ -z "$LINE" ] || [ "$LINE" = "${var}=" ]; then
    pass "$var has no leaked value (line: '${LINE:-absent}')"
  else
    fail "$var still has leaked value: '$LINE'"
  fi
done

# --- Test 2: --settings JSON is passed ---
run_test
if echo "$ARGV_DUMP" | grep -qFx -- '--settings'; then
  SETTINGS_LINE=$(echo "$ARGV_DUMP" | grep -A1 -Fx -- '--settings' | tail -n1)
  if [ "$SETTINGS_LINE" = '{"skipDangerousModePermissionPrompt":true}' ]; then
    pass "--settings flag passed with skipDangerousModePermissionPrompt"
  else
    fail "--settings value wrong: '$SETTINGS_LINE'"
  fi
else
  fail "--settings flag missing from argv"
fi

# --- Scenario B: missing consent + non-interactive stdin refuses to launch ---
run_test
NO_CONSENT_HOME=$(mktemp -d)
NO_CONSENT_TMUX="launch-test-no-consent-$$"
TMUX_NAMES+=("$NO_CONSENT_TMUX")
rm -f "$STUB_LOG"

NO_CONSENT_STDERR=$(mktemp)
set +e
HOME="$NO_CONSENT_HOME" PATH="$STUB_DIR:$PATH" \
  bash "$LAUNCH_WORKER" "$NO_CONSENT_TMUX" /tmp \
  </dev/null >/dev/null 2>"$NO_CONSENT_STDERR"
EXIT_CODE=$?
set -e

if [ "$EXIT_CODE" -eq 0 ]; then
  fail "launch-worker should refuse to run without consent (exit=$EXIT_CODE)"
elif ! grep -qi 'consent' "$NO_CONSENT_STDERR"; then
  fail "Error message should mention consent; got: $(cat "$NO_CONSENT_STDERR")"
elif ! grep -qF 'grant-consent.sh' "$NO_CONSENT_STDERR"; then
  fail "Error message should point at grant-consent.sh; got: $(cat "$NO_CONSENT_STDERR")"
elif [ -s "$STUB_LOG" ]; then
  fail "Stub claude should not have been invoked without consent"
elif tmux has-session -t "$NO_CONSENT_TMUX" 2>/dev/null; then
  fail "tmux session should not be created without consent"
else
  pass "launch refuses cleanly when consent file is absent and stdin is not a tty"
fi

rm -rf "$NO_CONSENT_HOME" "$NO_CONSENT_STDERR"

echo ""
echo "Results: $((TESTS - FAILURES))/$TESTS passed"
if [ "$FAILURES" -gt 0 ]; then
  exit 1
fi
exit 0
