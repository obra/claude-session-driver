#!/bin/bash
# Shared helpers for claude-session-driver scripts. Sourced, not executed.
#
# Functions defined here:
#   resolve_session <arg>   Print the session_id for a worker, given either
#                           the session_id directly (passes through if a
#                           matching .meta or .events.jsonl file exists) or
#                           the tmux_name (looked up via meta file). Exits
#                           non-zero with a message to stderr if neither
#                           matches a known worker.

_CSD_WORKER_DIR=/tmp/claude-workers

resolve_session() {
  local arg="$1"
  # If the arg directly corresponds to a known session_id (has either a meta
  # file or an events file), pass it through. This works for real UUID-style
  # session_ids as well as synthetic ones used by tests.
  if [ -f "$_CSD_WORKER_DIR/$arg.meta" ] || [ -f "$_CSD_WORKER_DIR/$arg.events.jsonl" ]; then
    echo "$arg"
    return 0
  fi
  # Otherwise treat as a tmux_name. Scan meta files for a match.
  local meta found
  found=""
  for meta in "$_CSD_WORKER_DIR"/*.meta; do
    [ -f "$meta" ] || continue
    if [ "$(jq -r '.tmux_name' "$meta" 2>/dev/null)" = "$arg" ]; then
      found=$(jq -r '.session_id' "$meta")
      break
    fi
  done
  if [ -z "$found" ]; then
    echo "Error: no worker known as '$arg' (searched $_CSD_WORKER_DIR/ for session_id or tmux_name match)" >&2
    return 1
  fi
  echo "$found"
}
