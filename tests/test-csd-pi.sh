#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCR="$SCRIPT_DIR/../skills/driving-claude-code-sessions/scripts"
PASS=0; FAIL=0
pass(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
fail(){ echo "  FAIL: $1 - $2"; FAIL=$((FAIL+1)); }
probe(){ ( source "$SCR/_lib.sh"; _load_driver pi; "$@" ); }

# --- manifest ---
[ "$(probe harness_id)" = "pi" ] && pass "id=pi" || fail "id" "wrong"
[ "$(probe harness_control_plane)" = "poll" ] && pass "control_plane=poll" || fail "cp" "wrong"
[ "$(probe harness_id_strategy)" = "derive" ] && pass "id_strategy=derive" || fail "ids" "wrong"
[ "$(probe harness_quit_keys)" = "/quit" ] && pass "quit=/quit" || fail "quit" "wrong"

# --- harness_poll self-registers the meta + synthesizes events ---
SD=$(mktemp -d); WDIR=$(mktemp -d)
SID="019e0000-0000-7000-8000-0000000000aa"
SF="$SD/2026-01-01T00-00-00-000Z_${SID}.jsonl"
{
  printf '{"type":"session","version":3,"id":"%s","cwd":"/w"}\n' "$SID"
  printf '{"type":"message","message":{"role":"user","content":[{"type":"text","text":"hi"}]}}\n'
  printf '{"type":"message","message":{"role":"assistant","stopReason":"toolUse","content":[{"type":"toolCall","name":"bash","arguments":{"command":"echo x"}}]}}\n'
  printf '{"type":"message","message":{"role":"toolResult","toolName":"bash","content":[{"type":"text","text":"x"}]}}\n'
  printf '{"type":"message","message":{"role":"assistant","stopReason":"stop","content":[{"type":"text","text":"PI_ANSWER"}]}}\n'
} > "$SF"
( source "$SCR/_lib.sh"; _load_driver pi; harness_poll "$SD" "$WDIR" "no-such-tmux-$$" ) >/dev/null 2>&1 || true
M=$(ls "$WDIR"/*.meta 2>/dev/null | head -1)
[ -n "$M" ] && [ "$(jq -r '.harness' "$M")" = "pi" ] && pass "poller self-registers pi meta" || fail "meta" "missing"
[ -n "$M" ] && [ "$(jq -r '.session_id' "$M")" = "$SID" ] && pass "meta has session id from line 1" || fail "sid" "wrong"
EV="${M%.meta}.events.jsonl"
ev_seq=$(jq -r '.event' "$EV" 2>/dev/null | tr '\n' ',')
echo "$ev_seq" | grep -q 'session_start,user_prompt_submit,pre_tool_use,post_tool_use,stop' && pass "poller synthesizes the event sequence" || fail "events" "got $ev_seq"
rm -rf "$SD" "$WDIR"

# --- prepare + launch + env slots ---
HOME_DIR=$(mktemp -d); CWD=$(mktemp -d)
( source "$SCR/_lib.sh"; _load_driver pi; CSD_PLUGIN_DIR=/plug HOME=/nonexistent harness_prepare wkr "$CWD" "$HOME_DIR" )
[ -d "$HOME_DIR/sessions" ] && pass "pi session dir created" || fail "session dir" "missing"
av=$( ( source "$SCR/_lib.sh"; _load_driver pi; harness_launch_argv launch "" "$CWD" /plug "$HOME_DIR" ) )
echo "$av" | grep -qx -- "--session-dir" && pass "pi --session-dir" || fail "--session-dir" "missing"
echo "$av" | grep -qx -- "--session-id" && fail "no sid" "should be absent" || pass "no --session-id"
ea=$( ( source "$SCR/_lib.sh"; _load_driver pi; WORKER_ENV_ARGS=(); harness_env_args; printf '%s\n' "${WORKER_ENV_ARGS[@]}" ) )
echo "$ea" | grep -q '^PI_CODING_AGENT_SESSION_DIR=' && pass "pi env session dir" || fail "env" "missing: $ea"

# --- parser slots ---
SF2=$(mktemp)
printf '%s\n' \
  '{"type":"session","version":3,"id":"x","cwd":"/w"}' \
  '{"type":"message","message":{"role":"user","content":[{"type":"text","text":"hi"}]}}' \
  '{"type":"message","message":{"role":"assistant","stopReason":"stop","content":[{"type":"text","text":"PI_HELLO"}]}}' > "$SF2"
out=$( ( source "$SCR/_lib.sh"; _load_driver pi; harness_parse_turn "$SF2" ) )
echo "$out" | grep -q "PI_HELLO" && pass "pi parse_turn renders text" || fail "parse" "got: $out"
lt=$( ( source "$SCR/_lib.sh"; _load_driver pi; harness_last_text "$SF2" ) )
[ "$lt" = "PI_HELLO" ] && pass "pi last_text" || fail "last_text" "got: $lt"
ct=$( ( source "$SCR/_lib.sh"; _load_driver pi; harness_count_text "$SF2" ) )
[ "$ct" = "1" ] && pass "pi count_text" || fail "count" "got: $ct"
rm -rf "$HOME_DIR" "$CWD" "$SF2"

# --- csd poll subcommand self-registers (self-exits vs a missing tmux) ---
SD3=$(mktemp -d); WD3=$(mktemp -d)
SID3="019e0000-0000-7000-8000-0000000000bb"
printf '{"type":"session","version":3,"id":"%s","cwd":"/w"}\n' "$SID3" > "$SD3/x_${SID3}.jsonl"
printf '{"type":"message","message":{"role":"assistant","stopReason":"stop","content":[{"type":"text","text":"Z"}]}}\n' >> "$SD3/x_${SID3}.jsonl"
bash "$SCR/csd" poll pi "$SD3" "$WD3" "no-tmux-$$" >/dev/null 2>&1 || true
[ -f "$WD3/$SID3.meta" ] && pass "csd poll self-registers" || fail "csd poll" "no meta"
rm -rf "$SD3" "$WD3"

echo "pi-driver: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
