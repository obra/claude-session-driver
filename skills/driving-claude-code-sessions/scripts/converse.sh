#!/bin/bash
set -euo pipefail

# Sends a prompt to a worker, waits for it to finish, and prints the worker's
# response. Combines send-prompt + wait-for-event + read into a single call.
#
# Usage: converse.sh [--with-turn] <session-id-or-tmux-name> <prompt-text> [timeout=120]
#
# By default prints only the final assistant text on stdout. With --with-turn,
# prints the full turn as markdown (via read-turn.sh) — useful when the worker
# is doing tool work and the bare text response strips out the interesting
# part.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"

WITH_TURN=0
if [ "${1:-}" = "--with-turn" ]; then
  WITH_TURN=1
  shift
fi

ID_OR_NAME="${1:?Usage: converse.sh [--with-turn] <session-id-or-tmux-name> <prompt-text> [timeout=120]}"
PROMPT_TEXT="${2:?Usage: converse.sh [--with-turn] <session-id-or-tmux-name> <prompt-text> [timeout=120]}"
TIMEOUT="${3:-120}"

SESSION_ID=$(resolve_session "$ID_OR_NAME")
META_FILE="/tmp/claude-workers/${SESSION_ID}.meta"
TMUX_NAME=$(jq -r '.tmux_name' "$META_FILE")
EVENT_FILE="/tmp/claude-workers/${SESSION_ID}.events.jsonl"

# Resolve the session log path (needed before and after the prompt)
CWD=$(jq -r '.cwd' "$META_FILE" 2>/dev/null)
if [ -z "$CWD" ] || [ "$CWD" = "null" ]; then
  echo "Error: Could not determine working directory from meta file" >&2
  exit 1
fi

# Resolve symlinks (e.g. /tmp -> /private/tmp on macOS) to match Claude's encoding
if [ -d "$CWD" ]; then
  CWD=$(cd "$CWD" && pwd -P)
fi

ENCODED_PATH=$(echo "$CWD" | sed 's|/|-|g')
LOG_FILE="$HOME/.claude/projects/${ENCODED_PATH}/${SESSION_ID}.jsonl"

# Helper: count assistant messages that contain at least one text content block.
# Uses jq -s to slurp all messages and count properly, avoiding line-counting
# issues with multi-line text responses.
count_text_messages() {
  if [ ! -f "$LOG_FILE" ]; then
    echo 0
    return
  fi
  local result
  result=$(grep '"type":"assistant"' "$LOG_FILE" \
    | jq -s '[.[] | select(.message.content | any(.type == "text"))] | length' 2>/dev/null) \
    || result=0
  echo "$result"
}

# Helper: extract the complete text from the last assistant message that has
# text content. Handles interleaved thinking/text blocks by filtering to
# messages with text, taking the last one, and joining all text blocks.
last_text_response() {
  grep '"type":"assistant"' "$LOG_FILE" \
    | jq -rs 'map(select(.message.content | any(.type == "text"))) | last | [.message.content[] | select(.type == "text") | .text] | join("\n")' 2>/dev/null
}

BEFORE_COUNT=$(count_text_messages)

# Record current event count for --after-line
AFTER_LINE=0
if [ -f "$EVENT_FILE" ]; then
  AFTER_LINE=$(wc -l < "$EVENT_FILE" | tr -d ' ')
fi

# Send the prompt
bash "$SCRIPT_DIR/send-prompt.sh" "$TMUX_NAME" "$PROMPT_TEXT"

# Wait for the worker to finish
if ! bash "$SCRIPT_DIR/wait-for-event.sh" "$SESSION_ID" stop "$TIMEOUT" --after-line "$AFTER_LINE" > /dev/null; then
  echo "Error: Worker did not finish within ${TIMEOUT}s" >&2
  exit 1
fi

# Wait for a new assistant text response to appear in the session log.
# The Stop event and session log write happen concurrently, so the log
# may not have the latest message yet when the stop event is detected.
for _ in $(seq 1 20); do
  if [ ! -f "$LOG_FILE" ]; then
    sleep 0.1
    continue
  fi
  AFTER_COUNT=$(count_text_messages)
  if [ "$AFTER_COUNT" -gt "$BEFORE_COUNT" ]; then
    if [ "$WITH_TURN" -eq 1 ]; then
      # Full markdown turn — preserves tool calls, thinking, and result blocks
      bash "$SCRIPT_DIR/read-turn.sh" "$SESSION_ID"
      exit 0
    fi
    RESPONSE=$(last_text_response)
    if [ -n "$RESPONSE" ]; then
      echo "$RESPONSE"
      exit 0
    fi
  fi
  sleep 0.1
done

echo "Error: Timed out waiting for assistant response in session log" >&2
exit 1
