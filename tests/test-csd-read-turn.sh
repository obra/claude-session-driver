#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CSD="$SCRIPT_DIR/../skills/driving-claude-code-sessions/scripts/csd"
WDIR=/tmp/csd-workers

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "  PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "  FAIL: $1 - $2"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# Use a synthetic HOME so we don't touch the real ~/.claude/projects.
FAKE_HOME=$(mktemp -d)
trap 'rm -rf "$FAKE_HOME"; rm -f /tmp/csd-workers/test-rt-*.meta /tmp/csd-workers/test-rt-*.events.jsonl' EXIT
mkdir -p "$WDIR"

SID="test-rt-001"
TMUX="test-rt"
CWD="$FAKE_HOME/proj"
mkdir -p "$CWD"
# Resolve symlinks so the encoded path matches what cmd_read_turn will produce
# (cmd_read_turn calls cd "$cwd" && pwd -P before encoding).
CWD=$(cd "$CWD" && pwd -P)
ENC=$(echo "$CWD" | sed 's|/|-|g')
LOG_DIR="$FAKE_HOME/.claude/projects/$ENC"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/$SID.jsonl"

echo "{\"tmux_name\":\"$TMUX\",\"session_id\":\"$SID\",\"cwd\":\"$CWD\"}" > "$WDIR/$SID.meta"

# Minimal log with one prompt and one assistant text reply
cat > "$LOG" <<'JSON'
{"type":"user","message":{"content":"Hello"}}
{"type":"assistant","message":{"content":[{"type":"text","text":"World"}]}}
JSON

OUTPUT=$(HOME="$FAKE_HOME" bash "$CSD" --worker "$TMUX" read-turn)
echo "$OUTPUT" | grep -q "Hello" && pass "prompt appears" || fail "prompt" "$OUTPUT"
echo "$OUTPUT" | grep -q "World" && pass "response appears" || fail "response" "$OUTPUT"

# --- --full truncation behavior ---
# Synthesize a log with a tool result that's longer than 5 lines, so the
# truncate-vs-full branch in read-turn's jq filter actually fires.
SID2="test-rt-002"
TMUX2="test-rt-full"
LOG2="$LOG_DIR/$SID2.jsonl"
echo "{\"tmux_name\":\"$TMUX2\",\"session_id\":\"$SID2\",\"cwd\":\"$CWD\"}" > "$WDIR/$SID2.meta"

# Build an 8-line tool result. Each line is distinct so we can verify which
# lines appear in the truncated vs full output.
TOOL_RESULT_CONTENT=$'line-1\nline-2\nline-3\nline-4\nline-5\nline-6\nline-7\nline-8'
TOOL_RESULT_JSON=$(jq -nc --arg c "$TOOL_RESULT_CONTENT" '$c')

cat > "$LOG2" <<JSON
{"type":"user","message":{"content":"run ls"}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","content":$TOOL_RESULT_JSON}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"done"}]}}
JSON

TRUNC=$(HOME="$FAKE_HOME" bash "$CSD" --worker "$TMUX2" read-turn)
FULL=$(HOME="$FAKE_HOME" bash "$CSD" --worker "$TMUX2" read-turn --full)

# Truncated: first 5 lines present, last 3 absent, summary "... (8 lines total)" appears.
if echo "$TRUNC" | grep -q "line-1" && echo "$TRUNC" | grep -q "line-5"; then
  pass "truncated output shows first 5 lines"
else
  fail "trunc head" "expected line-1..line-5 in: $TRUNC"
fi
if echo "$TRUNC" | grep -q "line-8"; then
  fail "trunc leak" "line-8 should be hidden in truncated mode"
else
  pass "truncated output hides lines past 5"
fi
if echo "$TRUNC" | grep -q "8 lines total"; then
  pass "truncated output has summary footer"
else
  fail "trunc footer" "expected '8 lines total', got: $TRUNC"
fi

# Full: all 8 lines present, no summary footer.
if echo "$FULL" | grep -q "line-1" && echo "$FULL" | grep -q "line-8"; then
  pass "--full shows all 8 lines"
else
  fail "full content" "expected line-1..line-8 in: $FULL"
fi
if echo "$FULL" | grep -q "8 lines total"; then
  fail "full footer" "--full should not show '8 lines total' summary"
else
  pass "--full omits truncation summary"
fi

# Missing log file errors clearly
rm -f "$LOG"
EC=0
HOME="$FAKE_HOME" bash "$CSD" --worker "$TMUX" read-turn 2>/dev/null || EC=$?
[ "$EC" -ne 0 ] && pass "missing log fails" || fail "missing log" "exit 0"

TOTAL=$((PASS_COUNT + FAIL_COUNT))
echo ""
echo "Results: $PASS_COUNT/$TOTAL passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
