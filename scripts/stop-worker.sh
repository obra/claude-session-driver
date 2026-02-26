#!/bin/bash
set -euo pipefail

# Gracefully stops a Claude Code worker target. Sends /exit, waits for
# session_end event, kills tmux session/window if needed, and cleans up files.
#
# Usage: stop-worker.sh <tmux-name> <session-id>

TMUX_NAME_INPUT="${1:?Usage: stop-worker.sh <tmux-name> <session-id>}"
SESSION_ID="${2:?Usage: stop-worker.sh <tmux-name> <session-id>}"
TMUX_NAME="$TMUX_NAME_INPUT"
TMUX_SCOPE="session"
if [[ "$TMUX_NAME" == *:* ]]; then
  TMUX_SCOPE="window"
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
META_FILE="/tmp/claude-workers/${SESSION_ID}.meta"

tmux_target_exists() {
  local target="$1"
  tmux list-panes -t "$target" >/dev/null 2>&1
}

# Prefer the tmux_name recorded for this session if the provided name no longer
# maps directly (for example, when namespace prefixing is enabled).
if [ -f "$META_FILE" ]; then
  META_SCOPE="$(jq -r '.tmux_scope // empty' "$META_FILE" 2>/dev/null || true)"
  if [ "$META_SCOPE" = "window" ] || [ "$META_SCOPE" = "session" ]; then
    TMUX_SCOPE="$META_SCOPE"
  fi
fi

if ! tmux_target_exists "$TMUX_NAME" && [ -f "$META_FILE" ]; then
  RESOLVED_TMUX_NAME="$(jq -r '.tmux_name // empty' "$META_FILE" 2>/dev/null || true)"
  if [ -n "$RESOLVED_TMUX_NAME" ] && tmux_target_exists "$RESOLVED_TMUX_NAME"; then
    TMUX_NAME="$RESOLVED_TMUX_NAME"
  fi
fi

# Send /exit command
if tmux_target_exists "$TMUX_NAME"; then
  tmux send-keys -t "$TMUX_NAME" -l '/exit'
  tmux send-keys -t "$TMUX_NAME" Enter

  # Wait up to 10 seconds for session_end
  if bash "$SCRIPT_DIR/wait-for-event.sh" "$SESSION_ID" session_end 10 > /dev/null 2>&1; then
    # Give tmux a moment to close
    sleep 1
  fi

  # Kill tmux target if still running
  if tmux_target_exists "$TMUX_NAME"; then
    if [ "$TMUX_SCOPE" = "window" ]; then
      tmux kill-window -t "$TMUX_NAME" 2>/dev/null || true
    else
      tmux kill-session -t "$TMUX_NAME" 2>/dev/null || true
    fi
  fi
fi

# Clean up files
rm -f "/tmp/claude-workers/${SESSION_ID}.events.jsonl"
rm -f "/tmp/claude-workers/${SESSION_ID}.meta"

echo "Worker $TMUX_NAME ($SESSION_ID) stopped and cleaned up"
