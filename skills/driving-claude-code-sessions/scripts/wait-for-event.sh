#!/bin/bash
set -euo pipefail

# Waits for a specific event type to appear in a session's event JSONL file.
# Polls the file for new lines, checking each for a matching .event field.
# Outputs the matching JSON line on stdout and exits 0 on match, exits 1 on timeout.
#
# Usage: wait-for-event.sh <session-id> <event-type> [timeout-seconds=60] [--after-line N]
#
# --after-line N: Skip the first N lines. Only match events appearing after line N.
#                 Use this in multi-turn patterns to avoid re-matching old events.

SESSION_ID="${1:?Usage: wait-for-event.sh <session-id> <event-type> [timeout-seconds] [--after-line N]}"
EVENT_TYPE="${2:?Usage: wait-for-event.sh <session-id> <event-type> [timeout-seconds] [--after-line N]}"
TIMEOUT="${3:-60}"

# Parse optional flags from remaining args
AFTER_LINE=0
shift 3 2>/dev/null || shift $#
while [ $# -gt 0 ]; do
  case "$1" in
    --after-line) AFTER_LINE="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

EVENT_FILE="/tmp/claude-workers/${SESSION_ID}.events.jsonl"
DEADLINE=$((SECONDS + TIMEOUT))

# Wait for the file to exist
while [ ! -f "$EVENT_FILE" ]; do
  if [ "$SECONDS" -ge "$DEADLINE" ]; then
    echo "Timeout waiting for event file: $EVENT_FILE" >&2
    exit 1
  fi
  sleep 0.5
done

# Track how many lines we've already checked (skip first AFTER_LINE lines)
LINES_CHECKED=$AFTER_LINE

# Poll for new lines
while [ "$SECONDS" -lt "$DEADLINE" ]; do
  CURRENT_LINES=$(wc -l < "$EVENT_FILE" | tr -d ' ')
  if [ "$CURRENT_LINES" -gt "$LINES_CHECKED" ]; then
    # Check new lines for a match
    MATCH=$(tail -n +"$((LINES_CHECKED + 1))" "$EVENT_FILE" \
      | jq -c "select(.event == \"$EVENT_TYPE\")" 2>/dev/null \
      | head -1)
    if [ -n "$MATCH" ]; then
      echo "$MATCH"
      exit 0
    fi
    LINES_CHECKED=$CURRENT_LINES
  fi
  sleep 0.5
done

echo "Timeout waiting for event '$EVENT_TYPE' (${TIMEOUT}s)" >&2
exit 1
