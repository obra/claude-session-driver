#!/bin/bash
set -euo pipefail

# Lists worker sessions. By default shows only workers whose tmux session is
# still alive — `--all` includes dead workers (meta files left behind because
# the tmux session went away without stop-worker.sh cleaning up).
#
# Output format (one line per worker, tab-separated):
#   <status>  <tmux_name>  <session_id>  <started_at>  <cwd>
#
# Usage: list-workers.sh [--all]

SHOW_DEAD=0
if [ "${1:-}" = "--all" ]; then
  SHOW_DEAD=1
fi

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
    [ "$SHOW_DEAD" -eq 0 ] && continue
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$STATUS" "$TMUX_NAME" "$SESSION_ID" "$STARTED_AT" "$CWD"
done
