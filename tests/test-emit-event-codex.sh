#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/emit-event-codex"
PASS=0; FAIL=0
pass(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
fail(){ echo "  FAIL: $1 - $2"; FAIL=$((FAIL+1)); }
WD=$(mktemp -d)
SID="019e0000-0000-7000-8000-000000000001"

# SessionStart self-registers the meta from the payload.
printf '%s' "{\"session_id\":\"$SID\",\"transcript_path\":\"/r/$SID.jsonl\",\"cwd\":\"/w\",\"hook_event_name\":\"SessionStart\"}" \
  | "$HOOK" my-worker /w "$WD"
[ -f "$WD/$SID.meta" ] && pass "meta self-registered" || fail "meta" "missing"
[ "$(jq -r '.harness' "$WD/$SID.meta")" = "codex" ] && pass "harness=codex" || fail "harness" "wrong"
[ "$(jq -r '.tmux_name' "$WD/$SID.meta")" = "my-worker" ] && pass "tmux_name baked" || fail "tmux_name" "wrong"
[ "$(jq -r '.transcript_path' "$WD/$SID.meta")" = "/r/$SID.jsonl" ] && pass "transcript_path captured" || fail "tp" "wrong"
[ "$(tail -1 "$WD/$SID.events.jsonl" | jq -r '.event')" = "session_start" ] && pass "session_start event" || fail "event" "wrong"

# PreToolUse carries the tool name.
printf '%s' "{\"session_id\":\"$SID\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\"}" | "$HOOK" my-worker /w "$WD"
[ "$(tail -1 "$WD/$SID.events.jsonl" | jq -r '.tool')" = "Bash" ] && pass "pre_tool_use tool" || fail "tool" "wrong"

# B2: escaped JSON in tool_input must survive (read -r). Without -r, the payload
# corrupts, jq bails, and no event is appended (tail would show the prior event).
printf '%s' '{"session_id":"'"$SID"'","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo \"hi\" && ls\nfoo"}}' | "$HOOK" my-worker /w "$WD"
got=$(tail -1 "$WD/$SID.events.jsonl" | jq -r '.tool_input.command')
[ "$got" = 'echo "hi" && ls
foo' ] && pass "escaped tool_input preserved (read -r)" || fail "escaped" "got: $got"

# PostToolUse maps explicitly (no GNU \L fallback).
printf '%s' "{\"session_id\":\"$SID\",\"hook_event_name\":\"PostToolUse\"}" | "$HOOK" my-worker /w "$WD"
[ "$(tail -1 "$WD/$SID.events.jsonl" | jq -r '.event')" = "post_tool_use" ] && pass "post_tool_use mapped" || fail "posttool" "wrong"

# Stop maps to turn-end.
printf '%s' "{\"session_id\":\"$SID\",\"hook_event_name\":\"Stop\"}" | "$HOOK" my-worker /w "$WD"
[ "$(tail -1 "$WD/$SID.events.jsonl" | jq -r '.event')" = "stop" ] && pass "stop event" || fail "stop" "wrong"

# Missing session_id → no-op, exit 0 (don't break the agent).
printf '%s' '{"hook_event_name":"Stop"}' | "$HOOK" my-worker /w "$WD" && pass "no-sid no-ops cleanly" || fail "no-sid" "nonzero exit"

rm -rf "$WD"
echo "emit-event-codex: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
