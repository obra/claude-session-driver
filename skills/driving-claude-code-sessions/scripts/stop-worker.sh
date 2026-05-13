#!/bin/bash
set -euo pipefail

# Gracefully stops a Claude Code worker session. Sends /exit, waits for
# session_end event, kills tmux session if needed, and cleans up files.
#
# Usage: stop-worker.sh <session-id>
#        stop-worker.sh <tmux-name> <session-id>     # legacy two-arg form
#
# With just <session-id>, tmux_name is resolved from the meta file. The
# legacy form is still accepted for back compat.

UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
if [[ "${1:-}" =~ $UUID_RE ]] && [ -z "${2:-}" ]; then
  SESSION_ID="$1"
  META_FILE="/tmp/claude-workers/${SESSION_ID}.meta"
  if [ ! -f "$META_FILE" ]; then
    echo "Error: no meta file for session $SESSION_ID at $META_FILE" >&2
    exit 1
  fi
  TMUX_NAME=$(jq -r '.tmux_name' "$META_FILE")
else
  TMUX_NAME="${1:?Usage: stop-worker.sh <session-id> [<tmux-name> <session-id> for legacy]}"
  SESSION_ID="${2:?Usage: stop-worker.sh <session-id> [<tmux-name> <session-id> for legacy]}"
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Send /exit command
if tmux has-session -t "$TMUX_NAME" 2>/dev/null; then
  tmux send-keys -t "$TMUX_NAME" -l '/exit'
  tmux send-keys -t "$TMUX_NAME" Enter

  # Wait up to 10 seconds for session_end
  if bash "$SCRIPT_DIR/wait-for-event.sh" "$SESSION_ID" session_end 10 > /dev/null 2>&1; then
    # Give tmux a moment to close
    sleep 1
  fi

  # Kill tmux session if still running
  if tmux has-session -t "$TMUX_NAME" 2>/dev/null; then
    tmux kill-session -t "$TMUX_NAME"
  fi
fi

# Clean up files
rm -f "/tmp/claude-workers/${SESSION_ID}.events.jsonl"
rm -f "/tmp/claude-workers/${SESSION_ID}.meta"

echo "Worker $TMUX_NAME ($SESSION_ID) stopped and cleaned up"
