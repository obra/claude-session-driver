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

# Absolute path to scripts/ (this file's dir). Used to locate drivers/.
_CSD_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the harness driver for <harness> (default claude). Drivers live at
# scripts/drivers/<harness>.sh and define the harness slot functions.
_load_driver() {
  local harness="${1:-claude}"
  local driver_file="$_CSD_SCRIPT_DIR/drivers/${harness}.sh"
  if [ ! -f "$driver_file" ]; then
    echo "Error: no driver for harness '$harness' (expected $driver_file)" >&2
    return 1
  fi
  # shellcheck source=/dev/null
  source "$driver_file"
}

_CSD_WORKER_DIR="${CSD_WORKER_DIR:-/tmp/csd-workers}"

# Event types emitted by the emit-event hook. Keep in sync with the case
# statement in hooks/emit-event.
_CSD_VALID_EVENTS="session_start user_prompt_submit pre_tool_use stop session_end"

validate_event_type() {
  local arg="$1"
  for e in $_CSD_VALID_EVENTS; do
    if [ "$arg" = "$e" ]; then
      return 0
    fi
  done
  echo "Error: '$arg' is not a known event type. Valid events: $_CSD_VALID_EVENTS" >&2
  return 1
}

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

# Print the tmux session name for <worker>, working even before a derive worker
# has self-registered (falls back to <worker> when it names a live tmux session —
# the shim sets --worker to the tmux_name).
_worker_tmux_name() {
  local worker="$1" sid tn
  sid=$(resolve_session "$worker" 2>/dev/null) || sid=""
  if [ -n "$sid" ] && [ -f "$_CSD_WORKER_DIR/${sid}.meta" ]; then
    tn=$(jq -r '.tmux_name' "$_CSD_WORKER_DIR/${sid}.meta" 2>/dev/null)
    [ -n "$tn" ] && [ "$tn" != "null" ] && { echo "$tn"; return 0; }
  fi
  if tmux has-session -t "$worker" 2>/dev/null; then echo "$worker"; return 0; fi
  echo "$worker"
}
