#!/bin/bash
set -euo pipefail

# Gracefully stops a Claude Code worker session. Sends /exit, waits for
# session_end event, kills tmux session if needed, and cleans up files.
#
# Usage: stop-worker.sh <tmux-name> <session-id>

TMUX_NAME="${1:?Usage: stop-worker.sh <tmux-name> <session-id>}"
SESSION_ID="${2:?Usage: stop-worker.sh <tmux-name> <session-id>}"

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
