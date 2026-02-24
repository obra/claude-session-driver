#!/bin/bash
set -euo pipefail

SESSION_ID="${1:?Usage: read-events.sh <session-id> [--last N] [--type event] [--follow]}"
shift

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/lib"
# shellcheck source=lib/transport.sh
source "$LIB_DIR/transport.sh"
csd_load_target "$SESSION_ID"

EVENT_FILE="/tmp/claude-workers/${SESSION_ID}.events.jsonl"

# For local target, check file exists upfront
if [ "${WORKER_TARGET:-local}" = "local" ] || [ -z "${WORKER_TARGET:-}" ]; then
  [ ! -f "$EVENT_FILE" ] && { echo "Error: No event file for session $SESSION_ID" >&2; exit 1; }
fi

LAST=""; TYPE=""; FOLLOW=false

while [ $# -gt 0 ]; do
  case "$1" in
    --last)   LAST="$2"; shift 2 ;;
    --type)   TYPE="$2"; shift 2 ;;
    --follow) FOLLOW=true; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [ "$FOLLOW" = true ]; then
  transport_tail "$EVENT_FILE" | while IFS= read -r line; do
    if [ -n "$TYPE" ]; then
      EVENT=$(echo "$line" | jq -r '.event // empty' 2>/dev/null) || continue
      [ "$EVENT" = "$TYPE" ] && echo "$line"
    else
      echo "$line"
    fi
  done
else
  DATA=$(transport_read "$EVENT_FILE")
  [ -n "$TYPE" ] && DATA=$(echo "$DATA" | jq -c "select(.event == \"$TYPE\")")
  if [ -n "$LAST" ]; then echo "$DATA" | tail -n "$LAST"; else echo "$DATA"; fi
fi
