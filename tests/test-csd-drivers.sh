#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCR="$SCRIPT_DIR/../skills/driving-claude-code-sessions/scripts"
PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1 - $2"; FAIL=$((FAIL+1)); }
probe() { ( source "$SCR/_lib.sh"; _load_driver claude; "$@" ); }

[ "$(probe harness_id)" = "claude" ] && pass "harness_id=claude" || fail "harness_id" "got $(probe harness_id)"
[ "$(probe harness_control_plane)" = "hooks" ] && pass "control_plane=hooks" || fail "control_plane" "wrong"
[ "$(probe harness_id_strategy)" = "assign" ] && pass "id_strategy=assign" || fail "id_strategy" "wrong"
[ "$(probe harness_quit_keys)" = "/exit" ] && pass "quit_keys=/exit" || fail "quit_keys" "wrong"
[ "$(probe harness_bin)" = "claude" ] && pass "bin defaults to claude" || fail "bin" "wrong"
[ "$(CSD_CLAUDE_BIN=/x/claude probe harness_bin)" = "/x/claude" ] && pass "bin honors CSD_CLAUDE_BIN" || fail "bin override" "wrong"
if ( source "$SCR/_lib.sh"; _load_driver nope ) 2>/dev/null; then fail "unknown driver" "should fail"; else pass "unknown driver errors"; fi

envprobe() { ( source "$SCR/_lib.sh"; _load_driver claude; "$@"; harness_env_args; printf '%s\n' "${WORKER_ENV_ARGS[@]}" ); }
out=$(unset CLAUDE_CODE_USE_BEDROCK; envprobe true)
echo "$out" | grep -qx "CLAUDE_CODE_SSE_PORT=" && pass "env: SSE_PORT pinned" || fail "env SSE_PORT" "missing"
echo "$out" | grep -qx "CLAUDE_CODE_USE_BEDROCK=" && pass "env: unset bedrock pinned empty" || fail "env bedrock unset" "missing"
out2=$(CLAUDE_CODE_USE_BEDROCK=1 envprobe true)
echo "$out2" | grep -qx "CLAUDE_CODE_USE_BEDROCK=" && fail "env set-bedrock" "should NOT pin a set var" || pass "env: set bedrock left to inherit"

echo "drivers: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
