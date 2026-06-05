#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CSD="$SCRIPT_DIR/../skills/driving-claude-code-sessions/scripts/csd"
WDIR=/tmp/csd-workers

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "  PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "  FAIL: $1 - $2"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

TMUX_NAME="test-csd-converse"
SID="test-conv-001"
TMUX_NAME2="test-csd-converse-wt"
SID2="test-conv-002"
TMUX_NAME3="test-csd-converse-null"
SID3="test-conv-003"

# Declare cleanup before first use; FAKE_HOME/LOG_DIR/LOG set after cleanup runs
FAKE_HOME=""
cleanup() {
  tmux kill-session -t "$TMUX_NAME" 2>/dev/null || true
  tmux kill-session -t "$TMUX_NAME2" 2>/dev/null || true
  tmux kill-session -t "$TMUX_NAME3" 2>/dev/null || true
  [ -n "$FAKE_HOME" ] && rm -rf "$FAKE_HOME"
  rm -f "$WDIR/$SID.meta" "$WDIR/$SID.events.jsonl"
  rm -f "$WDIR/$SID2.meta" "$WDIR/$SID2.events.jsonl"
  rm -f "$WDIR/$SID3.meta" "$WDIR/$SID3.events.jsonl"
}
trap cleanup EXIT
cleanup

# Create fresh temp dir after cleanup so it isn't immediately removed
FAKE_HOME=$(mktemp -d)
# Resolve through symlinks so macOS symlinked temp dirs don't cause path mismatch
FAKE_HOME=$(cd "$FAKE_HOME" && pwd -P)
CWD="$FAKE_HOME/proj"
mkdir -p "$CWD"
CWD=$(cd "$CWD" && pwd -P)
ENC=$(echo "$CWD" | sed 's|/|-|g')
LOG_DIR="$FAKE_HOME/.claude/projects/$ENC"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/$SID.jsonl"
mkdir -p "$WDIR"

# A fake worker pane that emits a user_prompt_submit event whenever it receives
# input — mirroring the real emit-event hook firing when Claude Code accepts a
# pasted prompt. cmd_send waits for this event to confirm submission (#20).
spawn_worker_pane() {  # $1=tmux_name  $2=events_file
  tmux new-session -d -s "$1" \
    "while IFS= read -r _l; do printf '%s\n' '{\"ts\":\"tps\",\"event\":\"user_prompt_submit\"}' >> '$2'; done"
}

# Set up: fake worker pane (confirms submission), meta with cwd, initial event
# file, pre-existing log with a prior turn.
spawn_worker_pane "$TMUX_NAME" "$WDIR/$SID.events.jsonl"
echo "{\"tmux_name\":\"$TMUX_NAME\",\"session_id\":\"$SID\",\"cwd\":\"$CWD\"}" > "$WDIR/$SID.meta"
echo '{"ts":"t0","event":"session_start","cwd":"'"$CWD"'"}' > "$WDIR/$SID.events.jsonl"

# Pre-existing log: one prior user/assistant exchange
cat > "$LOG" <<'JSON'
{"type":"user","message":{"content":"first prompt"}}
{"type":"assistant","message":{"content":[{"type":"text","text":"first response"}]}}
JSON

# Run converse in the background. It will send (no-op into cat), then wait
# for stop. Inject a new assistant message and a stop event after 0.5s.
(
  sleep 0.5
  cat >> "$LOG" <<'JSON'
{"type":"user","message":{"content":"second prompt"}}
{"type":"assistant","message":{"content":[{"type":"text","text":"second response"}]}}
JSON
  echo '{"ts":"t1","event":"stop"}' >> "$WDIR/$SID.events.jsonl"
) &

OUTPUT=$(HOME="$FAKE_HOME" bash "$CSD" --worker "$TMUX_NAME" converse "second prompt" 5)
EC=$?

[ "$EC" -eq 0 ] && pass "converse exits 0" || fail "exit" "got $EC; output: $OUTPUT"
echo "$OUTPUT" | grep -q "second response" && pass "returns new response text" || fail "text" "$OUTPUT"
echo "$OUTPUT" | grep -q "first response" && fail "returns old text" "should only return new" || pass "does not return old response"

# --- --with-turn returns full markdown rather than just text ---
LOG2="$LOG_DIR/$SID2.jsonl"
spawn_worker_pane "$TMUX_NAME2" "$WDIR/$SID2.events.jsonl"
echo "{\"tmux_name\":\"$TMUX_NAME2\",\"session_id\":\"$SID2\",\"cwd\":\"$CWD\"}" > "$WDIR/$SID2.meta"
echo '{"ts":"t0","event":"session_start","cwd":"'"$CWD"'"}' > "$WDIR/$SID2.events.jsonl"
cat > "$LOG2" <<'JSON'
{"type":"user","message":{"content":"earlier prompt"}}
{"type":"assistant","message":{"content":[{"type":"text","text":"earlier reply"}]}}
JSON

# Inject the new turn and stop event after a short delay, same shape as the
# first scenario but with a tool_use so the markdown form has something
# distinctive that plain text wouldn't carry.
(
  sleep 0.5
  cat >> "$LOG2" <<'JSON'
{"type":"user","message":{"content":"with-turn prompt"}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"echo hi"}},{"type":"text","text":"final text"}]}}
JSON
  echo '{"ts":"t1","event":"stop"}' >> "$WDIR/$SID2.events.jsonl"
) &

WT_OUTPUT=$(HOME="$FAKE_HOME" bash "$CSD" --worker "$TMUX_NAME2" converse --with-turn "with-turn prompt" 5)
WT_EC=$?

[ "$WT_EC" -eq 0 ] && pass "converse --with-turn exits 0" || fail "wt exit" "got $WT_EC; output: $WT_OUTPUT"
# read-turn renders prompts with a "**Prompt:**" header — plain converse never does.
echo "$WT_OUTPUT" | grep -q "\*\*Prompt:\*\*" && pass "--with-turn includes Prompt header (markdown form)" \
  || fail "wt markdown" "expected '**Prompt:**' in: $WT_OUTPUT"
# Tool call renders as "**Tool: Bash**" — also markdown-only.
echo "$WT_OUTPUT" | grep -q "\*\*Tool: Bash\*\*" && pass "--with-turn surfaces tool_use block" \
  || fail "wt tool" "expected tool_use markdown in: $WT_OUTPUT"
# The final text should still appear.
echo "$WT_OUTPUT" | grep -q "final text" && pass "--with-turn includes assistant text" \
  || fail "wt text" "$WT_OUTPUT"

# --- null .message.content must not break detection ---
# Regression: some Claude versions (e.g. 2.1.80) write assistant entries with
# message.content == null. jq `any(.type=="text")` over null throws "Cannot
# iterate over null", which the `2>/dev/null || r=0` swallow turned into a
# permanent count of 0 — so converse never saw a new response and timed out.
LOG3="$LOG_DIR/$SID3.jsonl"
spawn_worker_pane "$TMUX_NAME3" "$WDIR/$SID3.events.jsonl"
echo "{\"tmux_name\":\"$TMUX_NAME3\",\"session_id\":\"$SID3\",\"cwd\":\"$CWD\"}" > "$WDIR/$SID3.meta"
echo '{"ts":"t0","event":"session_start","cwd":"'"$CWD"'"}' > "$WDIR/$SID3.events.jsonl"
# Pre-existing log carries a null-content assistant message beside a real one.
cat > "$LOG3" <<'JSON'
{"type":"user","message":{"content":"prior prompt"}}
{"type":"assistant","message":{"content":[{"type":"text","text":"prior reply"}]}}
{"type":"assistant","message":{"content":null}}
JSON

# Inject another null-content message plus the real new response.
(
  sleep 0.5
  cat >> "$LOG3" <<'JSON'
{"type":"user","message":{"content":"null-safe prompt"}}
{"type":"assistant","message":{"content":null}}
{"type":"assistant","message":{"content":[{"type":"text","text":"null-safe response"}]}}
JSON
  echo '{"ts":"t1","event":"stop"}' >> "$WDIR/$SID3.events.jsonl"
) &

NULL_OUTPUT=$(HOME="$FAKE_HOME" bash "$CSD" --worker "$TMUX_NAME3" converse "null-safe prompt" 5)
NULL_EC=$?

[ "$NULL_EC" -eq 0 ] && pass "converse exits 0 with null content present" || fail "null exit" "got $NULL_EC; output: $NULL_OUTPUT"
echo "$NULL_OUTPUT" | grep -q "null-safe response" && pass "detects response past null content" || fail "null text" "$NULL_OUTPUT"
echo "$NULL_OUTPUT" | grep -q "prior reply" && fail "returns old text" "should only return new" || pass "null scenario does not return old response"

TOTAL=$((PASS_COUNT + FAIL_COUNT))
echo ""
echo "Results: $PASS_COUNT/$TOTAL passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
