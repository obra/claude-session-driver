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

argv_launch=$( ( source "$SCR/_lib.sh"; _load_driver claude; harness_launch_argv launch SID123 /cwd /plug /home ) )
[ "$(echo "$argv_launch" | head -1)" = "claude" ] && pass "launch argv starts with bin" || fail "launch argv bin" "wrong"
echo "$argv_launch" | grep -qx -- "--session-id" && echo "$argv_launch" | grep -qx "SID123" && pass "launch uses --session-id" || fail "launch sid" "wrong"
echo "$argv_launch" | grep -qx -- "--dangerously-skip-permissions" && pass "launch bypass flag" || fail "bypass" "wrong"
echo "$argv_launch" | grep -qx "AskUserQuestion" && pass "launch disallows AskUserQuestion" || fail "disallow" "wrong"
echo "$argv_launch" | grep -qFx '{"skipDangerousModePermissionPrompt":true}' && pass "settings is one token" || fail "settings token" "split"
argv_resume=$( ( source "$SCR/_lib.sh"; _load_driver claude; harness_launch_argv resume SID123 /cwd /plug /home ) )
echo "$argv_resume" | grep -qx -- "--resume" && pass "resume uses --resume" || fail "resume" "wrong"
echo "$argv_resume" | grep -qx -- "--session-id" && fail "resume sid" "should not use --session-id" || pass "resume omits --session-id"

envprobe() { ( source "$SCR/_lib.sh"; _load_driver claude; "$@"; harness_env_args; printf '%s\n' "${WORKER_ENV_ARGS[@]}" ); }
out=$(unset CLAUDE_CODE_USE_BEDROCK; envprobe true)
echo "$out" | grep -qx "CLAUDE_CODE_SSE_PORT=" && pass "env: SSE_PORT pinned" || fail "env SSE_PORT" "missing"
echo "$out" | grep -qx "CLAUDE_CODE_USE_BEDROCK=" && pass "env: unset bedrock pinned empty" || fail "env bedrock unset" "missing"
out2=$(CLAUDE_CODE_USE_BEDROCK=1 envprobe true)
echo "$out2" | grep -qx "CLAUDE_CODE_USE_BEDROCK=" && fail "env set-bedrock" "should NOT pin a set var" || pass "env: set bedrock left to inherit"

tp=$( ( source "$SCR/_lib.sh"; _load_driver claude; HOME=/home/x harness_transcript_path SID /a/b ) )
[ "$tp" = "/home/x/.claude/projects/-a-b/SID.jsonl" ] && pass "transcript_path formula" || fail "transcript_path" "got $tp"

# After a launch, the meta records harness=claude (back-compat default).
META_HOME=$(mktemp -d); mkdir -p "$META_HOME/.claude"; touch "$META_HOME/.claude/.claude-session-driver-consent"
META_FAKE=$(mktemp); cat > "$META_FAKE" <<'B'
#!/bin/bash
SID=""; while [ $# -gt 0 ]; do case "$1" in --session-id) SID="$2"; shift 2;; *) shift;; esac; done
mkdir -p /tmp/csd-workers
echo "{\"ts\":\"x\",\"event\":\"session_start\",\"cwd\":\"$PWD\"}" > "/tmp/csd-workers/${SID}.events.jsonl"; exec sleep 30
B
chmod +x "$META_FAKE"
META_TN="test-drivers-meta-$$"
CSD_CLAUDE_BIN="$META_FAKE" HOME="$META_HOME" bash "$SCR/csd" launch "$META_TN" /tmp >/dev/null 2>&1 || true
META=""
for m in /tmp/csd-workers/*.meta; do [ -f "$m" ] || continue; [ "$(jq -r '.tmux_name' "$m" 2>/dev/null)" = "$META_TN" ] && META="$m" && break; done
if [ -n "$META" ] && [ "$(jq -r '.harness' "$META")" = "claude" ]; then pass "meta records harness=claude"; else fail "meta harness" "got ${META:+$(jq -r '.harness' "$META" 2>/dev/null)}"; fi
tmux kill-session -t "$META_TN" 2>/dev/null || true
[ -n "$META" ] && { SID=$(basename "$META" .meta); rm -f "/tmp/csd-workers/$SID".* "/tmp/csd-workers/bin/$META_TN"; }
rm -rf "$META_HOME" "$META_FAKE"

echo "drivers: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
