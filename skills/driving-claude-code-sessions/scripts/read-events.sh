#!/bin/bash
set -euo pipefail

# Reads and filters the event stream for a session.
# Outputs matching JSONL lines to stdout.
#
# Usage: read-events.sh <session-id> [--last N] [--type <event>] [--follow]

SESSION_ID="${1:?Usage: read-events.sh <session-id> [--last N] [--type <event>] [--follow]}"
shift

EVENT_FILE="/tmp/claude-workers/${SESSION_ID}.events.jsonl"

if [ ! -f "$EVENT_FILE" ]; then
  echo "Error: No event file for session $SESSION_ID" >&2
  exit 1
fi

# Parse options
LAST=""
TYPE=""
FOLLOW=false

while [ $# -gt 0 ]; do
  case "$1" in
    --last)  LAST="$2"; shift 2 ;;
    --type)  TYPE="$2"; shift 2 ;;
    --follow) FOLLOW=true; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [ "$FOLLOW" = true ]; then
  tail -f "$EVENT_FILE" | while IFS= read -r line; do
    if [ -n "$TYPE" ]; then
      EVENT=$(echo "$line" | jq -r '.event // empty' 2>/dev/null) || continue
      [ "$EVENT" = "$TYPE" ] && echo "$line"
    else
      echo "$line"
    fi
  done
else
  DATA=$(cat "$EVENT_FILE")

  if [ -n "$TYPE" ]; then
    DATA=$(echo "$DATA" | jq -c "select(.event == \"$TYPE\")")
  fi

  if [ -n "$LAST" ]; then
    echo "$DATA" | tail -n "$LAST"
  else
    echo "$DATA"
  fi
fi
