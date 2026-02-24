#!/bin/bash
set -euo pipefail

TMUX_NAME="${1:?Usage: stop-worker.sh <tmux-name> <session-id>}"
SESSION_ID="${2:?Usage: stop-worker.sh <tmux-name> <session-id>}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/lib"
# shellcheck source=lib/transport.sh
source "$LIB_DIR/transport.sh"
csd_load_target "$SESSION_ID"

META_FILE="/tmp/claude-workers/${SESSION_ID}.meta"
CONTAINER_MANAGED=$(jq -r '.container_managed // false' "$META_FILE" 2>/dev/null || echo false)

if transport_exec tmux has-session -t "$TMUX_NAME" 2>/dev/null; then
  transport_exec tmux send-keys -t "$TMUX_NAME" -l '/exit'
  transport_exec tmux send-keys -t "$TMUX_NAME" Enter
  bash "$SCRIPT_DIR/wait-for-event.sh" "$SESSION_ID" session_end 10 > /dev/null 2>&1 && sleep 1
  transport_exec tmux has-session -t "$TMUX_NAME" 2>/dev/null \
    && transport_exec tmux kill-session -t "$TMUX_NAME"
fi

# Clean up ephemeral docker-run containers
if [ "$CONTAINER_MANAGED" = "true" ]; then
  TARGET=$(jq -r '.target' "$META_FILE" 2>/dev/null || echo "")
  if [[ "$TARGET" == docker://* ]]; then
    CONTAINER="${TARGET#docker://}"
    docker rm -f "$CONTAINER" 2>/dev/null || true
  fi
fi

rm -f "/tmp/claude-workers/${SESSION_ID}.events.jsonl"
rm -f "/tmp/claude-workers/${SESSION_ID}.tool-decision"
# For remote workers, the events and tool-decision files are on the remote machine
if [ "${WORKER_TARGET:-local}" != "local" ] && [ -n "${WORKER_TARGET:-}" ]; then
  transport_exec rm -f "/tmp/claude-workers/${SESSION_ID}.events.jsonl" 2>/dev/null || true
  transport_exec rm -f "/tmp/claude-workers/${SESSION_ID}.tool-decision" 2>/dev/null || true
fi
rm -f "$META_FILE"
echo "Worker $TMUX_NAME ($SESSION_ID) stopped and cleaned up"
