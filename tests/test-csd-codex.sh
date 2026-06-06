#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCR="$SCRIPT_DIR/../skills/driving-claude-code-sessions/scripts"
PASS=0; FAIL=0
pass(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
fail(){ echo "  FAIL: $1 - $2"; FAIL=$((FAIL+1)); }
probe(){ ( source "$SCR/_lib.sh"; _load_driver codex; "$@" ); }

# --- manifest ---
[ "$(probe harness_id)" = "codex" ] && pass "id=codex" || fail "id" "wrong"
[ "$(probe harness_control_plane)" = "hooks" ] && pass "control_plane=hooks" || fail "cp" "wrong"
[ "$(probe harness_id_strategy)" = "derive" ] && pass "id_strategy=derive" || fail "ids" "wrong"
[ "$(probe harness_quit_keys)" = "/quit" ] && pass "quit=/quit" || fail "quit" "wrong"
[ "$(probe harness_bin)" = "codex" ] && pass "bin=codex" || fail "bin" "wrong"

# --- prepare writes the per-worker config (HOME=/nonexistent skips auth copy) ---
HOME_DIR=$(mktemp -d); CWD=$(mktemp -d)
( source "$SCR/_lib.sh"; _load_driver codex; CSD_PLUGIN_DIR=/plug HOME=/nonexistent harness_prepare wkr "$CWD" "$HOME_DIR" )
[ -f "$HOME_DIR/config.toml" ] && pass "config.toml written" || fail "config" "missing"
grep -q "emit-event-codex wkr $CWD" "$HOME_DIR/config.toml" && pass "hook bakes tmux_name+cwd+workerdir" || fail "hook args" "missing"
grep -q '\[\[hooks.SessionStart\]\]' "$HOME_DIR/config.toml" && pass "SessionStart hook registered" || fail "sshook" "missing"
grep -q 'trust_level' "$HOME_DIR/config.toml" && pass "project trust" || fail "trust" "missing"

# --- launch argv: no --session-id; -C <cwd> + bypass flags ---
av=$( ( source "$SCR/_lib.sh"; _load_driver codex; harness_launch_argv launch "" "$CWD" /plug "$HOME_DIR" ) )
echo "$av" | grep -qx -- "--dangerously-bypass-approvals-and-sandbox" && pass "yolo flag" || fail "yolo" "missing"
echo "$av" | grep -qx -- "--session-id" && fail "no sid" "should be absent" || pass "no --session-id"
echo "$av" | grep -qx -- "-C" && pass "-C cwd flag" || fail "-C" "missing"

# --- env_args: CODEX_HOME, set -u safe when worker home unset ---
ea=$( ( source "$SCR/_lib.sh"; _load_driver codex; WORKER_ENV_ARGS=(); harness_env_args; printf '%s\n' "${WORKER_ENV_ARGS[@]}" ) )
echo "$ea" | grep -q '^CODEX_HOME=' && pass "env CODEX_HOME (set -u safe)" || fail "env" "missing: $ea"

# --- parse_turn renders a minimal rollout ---
ROLL=$(mktemp)
printf '%s\n' \
  '{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"hi"}]}}' \
  '{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"HELLO_CDX"}]}}' > "$ROLL"
out=$( ( source "$SCR/_lib.sh"; _load_driver codex; harness_parse_turn "$ROLL" ) )
echo "$out" | grep -q "HELLO_CDX" && pass "parse_turn renders assistant text" || fail "parse" "got: $out"

# --- count_text is single-valued on no-match (B4) ---
ct=$( ( source "$SCR/_lib.sh"; _load_driver codex; harness_count_text "$ROLL" ) )
[ "$ct" = "0" ] && pass "count_text single 0 on no agent_message" || fail "count" "got: [$ct]"

rm -rf "$HOME_DIR" "$CWD" "$ROLL"

# --- integration: fake-codex launch -> self-register -> read-turn -> status ---
FAKE="$SCRIPT_DIR/fixtures/fake-codex"; chmod +x "$FAKE" 2>/dev/null || true
IHOME=$(mktemp -d); mkdir -p "$IHOME/.claude"; touch "$IHOME/.claude/.claude-session-driver-consent"
IWDIR=$(mktemp -d); ITN="test-codex-$$"; IWD=$(mktemp -d)
run_csd(){ CSD_WORKER_DIR="$IWDIR" CSD_CODEX_BIN="$FAKE" HOME="$IHOME" bash "$SCR/csd" "$@"; }
run_csd launch --harness codex "$ITN" "$IWD" >/dev/null 2>&1 || true
sleep 1
OUT=$(run_csd --worker "$ITN" read-turn 2>/dev/null || true)
echo "$OUT" | grep -q "FAKE_DONE" && pass "codex read-turn renders the turn" || fail "codex read-turn" "got: $OUT"
ST=$(run_csd --worker "$ITN" status 2>/dev/null || true)
[ "$ST" = "idle" ] && pass "codex status idle after stop event" || fail "codex status" "got: $ST"
# meta self-registered with harness=codex
M=$(ls "$IWDIR"/*.meta 2>/dev/null | head -1)
[ -n "$M" ] && [ "$(jq -r '.harness' "$M")" = "codex" ] && pass "codex meta self-registered" || fail "codex meta" "missing/wrong"
# Multi-turn safety (regression for the derive after_line/before_count bug):
# the worker confirms the prompt but produces no NEW completed turn, so a correct
# converse must keep waiting and NOT echo the stale boot turn's answer.
OUT2=$(run_csd --worker "$ITN" converse "again please" 4 2>/dev/null || true)
echo "$OUT2" | grep -q FAKE_DONE && fail "converse stale-turn" "echoed the prior turn: $OUT2" || pass "converse waits for a new turn (no stale answer)"
run_csd --worker "$ITN" stop >/dev/null 2>&1 || true
tmux kill-session -t "$ITN" 2>/dev/null || true
rm -rf "$IHOME" "$IWD" "$IWDIR"

echo "codex-driver: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
