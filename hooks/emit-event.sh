#!/bin/bash
set -euo pipefail

# Hook script called by Claude Code for session lifecycle events.
# Reads hook input JSON from stdin and appends a JSONL event line
# to /tmp/claude-workers/<session_id>.events.jsonl.
#
# Only activates for worker sessions launched by the session driver.

INPUT=$(cat)

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id')

# Only emit events for managed worker sessions.
if [ ! -f "/tmp/claude-workers/${SESSION_ID}.meta" ]; then
  exit 0
fi

HOOK_EVENT=$(echo "$INPUT" | jq -r '.hook_event_name')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

# Map hook event names to snake_case
case "$HOOK_EVENT" in
  SessionStart)     EVENT="session_start" ;;
  Stop)             EVENT="stop" ;;
  UserPromptSubmit) EVENT="user_prompt_submit" ;;
  SessionEnd)       EVENT="session_end" ;;
  *)                EVENT=$(echo "$HOOK_EVENT" | sed 's/\([A-Z]\)/_\L\1/g' | sed 's/^_//') ;;
esac

mkdir -p /tmp/claude-workers

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# SessionStart includes cwd; other events do not
if [ "$EVENT" = "session_start" ] && [ -n "$CWD" ]; then
  EVENT_JSON=$(jq -cn --arg ts "$TIMESTAMP" --arg event "$EVENT" --arg cwd "$CWD" \
    '{ts: $ts, event: $event, cwd: $cwd}')
else
  EVENT_JSON=$(jq -cn --arg ts "$TIMESTAMP" --arg event "$EVENT" \
    '{ts: $ts, event: $event}')
fi

EVENT_FILE="/tmp/claude-workers/${SESSION_ID}.events.jsonl"
echo "$EVENT_JSON" >> "$EVENT_FILE"

# For Stop events, approve so we never block the agent
if [ "$HOOK_EVENT" = "Stop" ]; then
  echo '{"decision":"approve"}'
fi
