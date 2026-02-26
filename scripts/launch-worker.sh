#!/bin/bash
set -euo pipefail

# Launches a Claude Code worker session in a detached tmux session with the
# session-driver plugin loaded for lifecycle event emission.
#
# Usage: launch-worker.sh <tmux-name> <working-dir> [extra claude args...]

REQUESTED_TMUX_NAME="${1:?Usage: launch-worker.sh <tmux-name> <working-dir> [extra claude args...]}"
WORKING_DIR="${2:?Usage: launch-worker.sh <tmux-name> <working-dir> [extra claude args...]}"
shift 2
EXTRA_ARGS=("$@")

# Resolve plugin directory (parent of scripts/)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CLAUDE_LAUNCH_BIN="${CLAUDE_SESSION_DRIVER_LAUNCH_CMD:-claude}"

# Resolve worker tmux target. By default, workers are launched as tmux sessions.
# Set CLAUDE_SESSION_DRIVER_TMUX_SCOPE=window to launch workers as windows
# inside a parent tmux session.
NAMESPACE_MODE="${CLAUDE_SESSION_DRIVER_TMUX_NAMESPACE_MODE:-inherit}"
NAMESPACE_DELIM="${CLAUDE_SESSION_DRIVER_TMUX_NAMESPACE_DELIM:--}"
TMUX_NAMESPACE="${CLAUDE_SESSION_DRIVER_TMUX_NAMESPACE:-}"
TMUX_SCOPE="${CLAUDE_SESSION_DRIVER_TMUX_SCOPE:-session}"
INFER_NAMESPACE="${CLAUDE_SESSION_DRIVER_INFER_NAMESPACE:-false}"

case "$NAMESPACE_MODE" in
  inherit|off)
    ;;
  *)
    echo "Error: invalid CLAUDE_SESSION_DRIVER_TMUX_NAMESPACE_MODE '$NAMESPACE_MODE' (use inherit|off)" >&2
    exit 1
    ;;
esac

case "$TMUX_SCOPE" in
  session|window)
    ;;
  *)
    echo "Error: invalid CLAUDE_SESSION_DRIVER_TMUX_SCOPE '$TMUX_SCOPE' (use session|window)" >&2
    exit 1
    ;;
esac

case "$INFER_NAMESPACE" in
  true|false)
    ;;
  *)
    echo "Error: invalid CLAUDE_SESSION_DRIVER_INFER_NAMESPACE '$INFER_NAMESPACE' (use true|false)" >&2
    exit 1
    ;;
esac

if [ -z "$TMUX_NAMESPACE" ] && [ "$NAMESPACE_MODE" = "inherit" ]; then
  if [ -n "${TMUX:-}" ]; then
    TMUX_NAMESPACE="$(tmux display-message -p '#S' 2>/dev/null || true)"
  fi
  if [ -z "$TMUX_NAMESPACE" ] && [ -n "${TMUX_BEADS_SESSION:-}" ]; then
    TMUX_NAMESPACE="$TMUX_BEADS_SESSION"
  fi
  if [ -z "$TMUX_NAMESPACE" ] && [ -n "${TMUX_BEADS_MANAGER_TARGET:-}" ]; then
    TMUX_NAMESPACE="${TMUX_BEADS_MANAGER_TARGET%%:*}"
  fi
  if [ -z "$TMUX_NAMESPACE" ] && [ -n "${BEADS_MANAGER_TARGET:-}" ]; then
    TMUX_NAMESPACE="${BEADS_MANAGER_TARGET%%:*}"
  fi
  if [ -z "$TMUX_NAMESPACE" ] && [ "$INFER_NAMESPACE" = "true" ]; then
    CLIENT_SESSIONS="$(tmux list-clients -F '#{session_name}' 2>/dev/null | sort -u | awk 'NF')"
    CLIENT_SESSION_COUNT="$(printf '%s\n' "$CLIENT_SESSIONS" | awk 'NF' | wc -l | tr -d ' ')"
    if [ "$CLIENT_SESSION_COUNT" = "1" ]; then
      TMUX_NAMESPACE="$CLIENT_SESSIONS"
    fi
  fi
fi

TMUX_NAME="$REQUESTED_TMUX_NAME"
WINDOW_NAME=""
if [ "$TMUX_SCOPE" = "session" ]; then
  if [ "$NAMESPACE_MODE" = "inherit" ] && [ -n "$TMUX_NAMESPACE" ]; then
    case "$REQUESTED_TMUX_NAME" in
      "$TMUX_NAMESPACE"|"$TMUX_NAMESPACE${NAMESPACE_DELIM}"*)
        TMUX_NAME="$REQUESTED_TMUX_NAME"
        ;;
      *)
        TMUX_NAME="${TMUX_NAMESPACE}${NAMESPACE_DELIM}${REQUESTED_TMUX_NAME}"
        ;;
    esac
  fi
else
  if [[ "$REQUESTED_TMUX_NAME" == *:* ]]; then
    TMUX_NAME="$REQUESTED_TMUX_NAME"
    TMUX_NAMESPACE="${TMUX_NAME%%:*}"
    WINDOW_NAME="${TMUX_NAME#*:}"
  else
    if [ -z "$TMUX_NAMESPACE" ]; then
      echo "Error: cannot resolve parent tmux session for window scope; set CLAUDE_SESSION_DRIVER_TMUX_NAMESPACE or run inside tmux" >&2
      exit 1
    fi
    TMUX_NAME="${TMUX_NAMESPACE}:${REQUESTED_TMUX_NAME}"
    WINDOW_NAME="$REQUESTED_TMUX_NAME"
  fi
fi

# Resolve working directory to absolute physical path (resolves symlinks)
WORKING_DIR="$(cd "$WORKING_DIR" && pwd -P)"

# Generate session ID
SESSION_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')

# Ensure output directory exists
mkdir -p /tmp/claude-workers

# Write metadata
jq -n \
  --arg tmux_name "$TMUX_NAME" \
  --arg tmux_scope "$TMUX_SCOPE" \
  --arg requested_tmux_name "$REQUESTED_TMUX_NAME" \
  --arg tmux_namespace "$TMUX_NAMESPACE" \
  --arg session_id "$SESSION_ID" \
  --arg cwd "$WORKING_DIR" \
  --arg started_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  '{
    tmux_name: $tmux_name,
    tmux_scope: $tmux_scope,
    requested_tmux_name: $requested_tmux_name,
    tmux_namespace: ($tmux_namespace | if . == "" then null else . end),
    session_id: $session_id,
    cwd: $cwd,
    started_at: $started_at
  }' \
  > "/tmp/claude-workers/${SESSION_ID}.meta"

# Check for existing tmux target with this name
if [ "$TMUX_SCOPE" = "session" ]; then
  if tmux has-session -t "$TMUX_NAME" 2>/dev/null; then
    echo "Error: tmux session '$TMUX_NAME' already exists" >&2
    rm -f "/tmp/claude-workers/${SESSION_ID}.meta"
    exit 1
  fi
else
  if tmux list-panes -t "$TMUX_NAME" >/dev/null 2>&1; then
    echo "Error: tmux window target '$TMUX_NAME' already exists" >&2
    rm -f "/tmp/claude-workers/${SESSION_ID}.meta"
    exit 1
  fi
fi

# Propagate approval timeout through tmux to the hook environment
APPROVAL_TIMEOUT="${CLAUDE_SESSION_DRIVER_APPROVAL_TIMEOUT:-30}"

# Resolve launch binary without shell evaluation.
if [[ "$CLAUDE_LAUNCH_BIN" == *[[:space:]]* ]]; then
  echo "Error: CLAUDE_SESSION_DRIVER_LAUNCH_CMD must be an executable name or path, not a shell command" >&2
  rm -f "/tmp/claude-workers/${SESSION_ID}.meta"
  exit 1
fi

if [[ "$CLAUDE_LAUNCH_BIN" == */* ]]; then
  if [ ! -x "$CLAUDE_LAUNCH_BIN" ]; then
    echo "Error: launch command '$CLAUDE_LAUNCH_BIN' is not executable" >&2
    rm -f "/tmp/claude-workers/${SESSION_ID}.meta"
    exit 1
  fi
else
  if ! CLAUDE_LAUNCH_BIN="$(command -v "$CLAUDE_LAUNCH_BIN" 2>/dev/null)"; then
    echo "Error: launch command '${CLAUDE_SESSION_DRIVER_LAUNCH_CMD:-claude}' was not found in PATH" >&2
    rm -f "/tmp/claude-workers/${SESSION_ID}.meta"
    exit 1
  fi
fi

LAUNCH_ARGS=(
  "$CLAUDE_LAUNCH_BIN"
  --session-id "$SESSION_ID"
  --plugin-dir "$PLUGIN_DIR"
  --dangerously-skip-permissions
)
for arg in "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"; do
  LAUNCH_ARGS+=("$arg")
done

if [ "$TMUX_SCOPE" = "session" ]; then
  if ! tmux new-session -d -s "$TMUX_NAME" -c "$WORKING_DIR" \
    -e "CLAUDE_SESSION_DRIVER_APPROVAL_TIMEOUT=$APPROVAL_TIMEOUT" \
    -e "CLAUDECODE=" \
    "${LAUNCH_ARGS[@]}"; then
    rm -f "/tmp/claude-workers/${SESSION_ID}.meta"
    exit 1
  fi
else
  if ! tmux new-window -d -t "$TMUX_NAMESPACE" -n "$WINDOW_NAME" -c "$WORKING_DIR" \
    -e "CLAUDE_SESSION_DRIVER_APPROVAL_TIMEOUT=$APPROVAL_TIMEOUT" \
    -e "CLAUDECODE=" \
    "${LAUNCH_ARGS[@]}"; then
    rm -f "/tmp/claude-workers/${SESSION_ID}.meta"
    exit 1
  fi
fi

# Accept the workspace trust dialog (default selection is "Yes, I trust this folder")
sleep 3
tmux send-keys -t "$TMUX_NAME" Enter

# Wait for session to start
WAIT_SCRIPT="$SCRIPT_DIR/wait-for-event.sh"
if ! bash "$WAIT_SCRIPT" "$SESSION_ID" session_start 30 > /dev/null; then
  echo "Error: Worker session failed to start within 30 seconds" >&2
  if [ "$TMUX_SCOPE" = "session" ]; then
    tmux kill-session -t "$TMUX_NAME" 2>/dev/null || true
  else
    tmux kill-window -t "$TMUX_NAME" 2>/dev/null || true
  fi
  rm -f "/tmp/claude-workers/${SESSION_ID}.meta" "/tmp/claude-workers/${SESSION_ID}.events.jsonl"
  exit 1
fi

# Output session info
jq -n \
  --arg session_id "$SESSION_ID" \
  --arg tmux_name "$TMUX_NAME" \
  --arg tmux_scope "$TMUX_SCOPE" \
  --arg requested_tmux_name "$REQUESTED_TMUX_NAME" \
  --arg events_file "/tmp/claude-workers/${SESSION_ID}.events.jsonl" \
  '{session_id: $session_id, tmux_name: $tmux_name, tmux_scope: $tmux_scope, requested_tmux_name: $requested_tmux_name, events_file: $events_file}'
