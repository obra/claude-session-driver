#!/bin/bash
set -euo pipefail

# Lists every worker the plugin knows about. Joins /tmp/claude-workers/*.meta
# with `tmux has-session` to show which workers are still alive vs whose tmux
# session has gone away.
#
# Output format (one line per worker, tab-separated):
#   <status>  <tmux_name>  <session_id>  <started_at>  <cwd>
#
# status is `alive` if the tmux session is still up, `dead` otherwise. Dead
# workers usually mean the controller forgot to call stop-worker.sh — clean
# up with `stop-worker.sh <session-id>` or `rm /tmp/claude-workers/<id>.*`.

WORKER_DIR=/tmp/claude-workers

if [ ! -d "$WORKER_DIR" ] || [ -z "$(ls -A "$WORKER_DIR"/*.meta 2>/dev/null)" ]; then
  echo "No workers found" >&2
  exit 0
fi

for meta in "$WORKER_DIR"/*.meta; do
  [ -f "$meta" ] || continue
  TMUX_NAME=$(jq -r '.tmux_name' "$meta")
  SESSION_ID=$(jq -r '.session_id' "$meta")
  STARTED_AT=$(jq -r '.started_at' "$meta")
  CWD=$(jq -r '.cwd' "$meta")
  if tmux has-session -t "$TMUX_NAME" 2>/dev/null; then
    STATUS=alive
  else
    STATUS=dead
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$STATUS" "$TMUX_NAME" "$SESSION_ID" "$STARTED_AT" "$CWD"
done
