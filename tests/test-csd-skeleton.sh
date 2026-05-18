#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CSD="$SCRIPT_DIR/../skills/driving-claude-code-sessions/scripts/csd"

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "  PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "  FAIL: $1 - $2"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# --- Test 1: csd with no args prints usage and exits non-zero ---
echo "Test 1: csd with no args prints usage"
EXIT_CODE=0
OUTPUT=$(bash "$CSD" 2>&1) || EXIT_CODE=$?
if [ "$EXIT_CODE" -ne 0 ]; then
  pass "exits non-zero with no args"
else
  fail "exit code" "expected non-zero, got 0"
fi
if echo "$OUTPUT" | grep -q "Usage:"; then
  pass "prints Usage line"
else
  fail "usage line" "expected 'Usage:' in output, got: $OUTPUT"
fi

# --- Test 2: csd help lists every documented subcommand ---
echo "Test 2: csd help lists all subcommands"
OUTPUT=$(bash "$CSD" help 2>&1 || true)
for sub in launch list grant-consent converse send wait-for-turn status \
           read-events read-turn stop handoff session-id events-file; do
  if echo "$OUTPUT" | grep -qw "$sub"; then
    pass "help mentions $sub"
  else
    fail "help missing $sub" "$sub not in help output"
  fi
done

# --- Test 3: unknown subcommand errors clearly ---
echo "Test 3: unknown subcommand fails with message"
EXIT_CODE=0
OUTPUT=$(bash "$CSD" frobnicate 2>&1) || EXIT_CODE=$?
if [ "$EXIT_CODE" -ne 0 ] && echo "$OUTPUT" | grep -qi "unknown"; then
  pass "rejects unknown subcommand"
else
  fail "unknown subcommand" "expected non-zero + error message"
fi

# --- Test 4: top-level subcommands reject --worker ---
echo "Test 4: --worker rejected on top-level subcommands"
for sub in launch list grant-consent; do
  EXIT_CODE=0
  OUTPUT=$(bash "$CSD" --worker foo "$sub" 2>&1) || EXIT_CODE=$?
  if [ "$EXIT_CODE" -ne 0 ] && echo "$OUTPUT" | grep -qi "worker"; then
    pass "$sub rejects --worker"
  else
    fail "$sub" "expected --worker rejection"
  fi
done

# --- Test 5: per-worker subcommands require --worker ---
echo "Test 5: per-worker subcommands require --worker"
for sub in status session-id events-file send wait-for-turn read-events \
           read-turn converse stop handoff; do
  EXIT_CODE=0
  OUTPUT=$(bash "$CSD" "$sub" 2>&1) || EXIT_CODE=$?
  if [ "$EXIT_CODE" -ne 0 ] && echo "$OUTPUT" | grep -qi "worker"; then
    pass "$sub requires --worker"
  else
    fail "$sub" "expected --worker required error"
  fi
done

# --- Test 6: --worker with no value errors cleanly ---
echo "Test 6: --worker with no value errors cleanly"
EXIT_CODE=0
OUTPUT=$(bash "$CSD" --worker 2>&1) || EXIT_CODE=$?
if [ "$EXIT_CODE" -eq 2 ] && echo "$OUTPUT" | grep -qi "worker"; then
  pass "--worker with no value exits 2 with error message"
else
  fail "--worker no value" "expected exit 2 and error message, got exit=$EXIT_CODE output=$OUTPUT"
fi

TOTAL=$((PASS_COUNT + FAIL_COUNT))
echo ""
echo "Results: $PASS_COUNT/$TOTAL passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
