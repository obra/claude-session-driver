#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_DIR="$PLUGIN_DIR/lib"
# shellcheck source=lib/transport.sh
source "$LIB_DIR/transport.sh"

# Parse arguments
TMUX_NAME=""
WORKING_DIR=""
TARGET="local"
SYNC_HOOKS=true
EXTRA_ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --name)          TMUX_NAME="$2"; shift 2 ;;
    --workdir)       WORKING_DIR="$2"; shift 2 ;;
    --target)        TARGET="$2"; shift 2 ;;
    --no-sync-hooks) SYNC_HOOKS=false; shift ;;
    --)              shift; EXTRA_ARGS+=("$@"); break ;;
    *)               EXTRA_ARGS+=("$1"); shift ;;
  esac
done

[ -z "$TMUX_NAME" ]   && { echo "Error: --name required" >&2; exit 1; }
[ -z "$WORKING_DIR" ] && { echo "Error: --workdir required" >&2; exit 1; }

if command -v uuidgen &>/dev/null; then
  SESSION_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')
elif [ -r /proc/sys/kernel/random/uuid ]; then
  SESSION_ID=$(cat /proc/sys/kernel/random/uuid)
else
  SESSION_ID=$(python3 -c "import uuid; print(str(uuid.uuid4()))")
fi

mkdir -p /tmp/claude-workers

# Determine effective target (docker-run:// → docker://csd-$SESSION_ID)
EFFECTIVE_TARGET="$TARGET"
CONTAINER_MANAGED=false
if [[ "$TARGET" == docker-run://* ]]; then
  IMAGE="${TARGET#docker-run://}"
  CONTAINER_NAME="csd-$SESSION_ID"
  docker run -d --name "$CONTAINER_NAME" "$IMAGE" sleep infinity \
    || { echo "Error: Failed to start Docker container '$CONTAINER_NAME'" >&2; exit 1; }
  EFFECTIVE_TARGET="docker://$CONTAINER_NAME"
  CONTAINER_MANAGED=true
fi

export WORKER_TARGET="$EFFECTIVE_TARGET"

# Resolve local workdir symlinks only when running locally
if [ "$EFFECTIVE_TARGET" = "local" ] || [ -z "$EFFECTIVE_TARGET" ]; then
  WORKING_DIR="$(cd "$WORKING_DIR" && pwd -P)"
fi

# Get effective home dir for session log resolution
if [ "$EFFECTIVE_TARGET" = "local" ] || [ -z "$EFFECTIVE_TARGET" ]; then
  WORKER_HOME="$HOME"
else
  WORKER_HOME=$(transport_exec sh -c 'printf "%s" "$HOME"' 2>/dev/null || echo "$HOME")
fi

# Write .meta
jq -n \
  --arg tmux_name "$TMUX_NAME" \
  --arg session_id "$SESSION_ID" \
  --arg cwd "$WORKING_DIR" \
  --arg started_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  --arg target "$EFFECTIVE_TARGET" \
  --argjson container_managed "$CONTAINER_MANAGED" \
  --arg worker_home "$WORKER_HOME" \
  '{tmux_name: $tmux_name, session_id: $session_id, cwd: $cwd,
    started_at: $started_at, target: $target,
    container_managed: $container_managed, worker_home: $worker_home}' \
  > "/tmp/claude-workers/${SESSION_ID}.meta"

# Sync hooks to remote
REMOTE_PLUGIN_DIR="/tmp/csd-hooks-$SESSION_ID"

if [ "$SYNC_HOOKS" = true ] && [ "$EFFECTIVE_TARGET" != "local" ] && [ -n "$EFFECTIVE_TARGET" ]; then
  case "$EFFECTIVE_TARGET" in
    ssh://*)
      HOST="${EFFECTIVE_TARGET#ssh://}"
      ssh "$HOST" "mkdir -p $REMOTE_PLUGIN_DIR"
      scp -r "$PLUGIN_DIR/hooks" "$PLUGIN_DIR/.claude-plugin" "$HOST:$REMOTE_PLUGIN_DIR/"
      ;;
    docker://*)
      CONTAINER="${EFFECTIVE_TARGET#docker://}"
      docker exec "$CONTAINER" mkdir -p "$REMOTE_PLUGIN_DIR"
      docker cp "$PLUGIN_DIR/hooks" "$CONTAINER:$REMOTE_PLUGIN_DIR/hooks"
      docker cp "$PLUGIN_DIR/.claude-plugin" "$CONTAINER:$REMOTE_PLUGIN_DIR/.claude-plugin"
      ;;
  esac
fi

# Choose plugin dir for worker
if [ "$EFFECTIVE_TARGET" = "local" ] || [ -z "$EFFECTIVE_TARGET" ]; then
  WORKER_PLUGIN_DIR="$PLUGIN_DIR"
else
  WORKER_PLUGIN_DIR="$REMOTE_PLUGIN_DIR"
fi

# Check tmux session does not already exist
if transport_exec tmux has-session -t "$TMUX_NAME" 2>/dev/null; then
  echo "Error: tmux session '$TMUX_NAME' already exists" >&2
  rm -f "/tmp/claude-workers/${SESSION_ID}.meta"
  exit 1
fi

APPROVAL_TIMEOUT="${CLAUDE_SESSION_DRIVER_APPROVAL_TIMEOUT:-30}"

transport_exec tmux new-session -d -s "$TMUX_NAME" -c "$WORKING_DIR" \
  -e "CLAUDE_SESSION_DRIVER_APPROVAL_TIMEOUT=$APPROVAL_TIMEOUT" \
  claude --session-id "$SESSION_ID" \
         --plugin-dir "$WORKER_PLUGIN_DIR" \
         --dangerously-skip-permissions \
         "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"

sleep 3
transport_exec tmux send-keys -t "$TMUX_NAME" Enter

WAIT_SCRIPT="$SCRIPT_DIR/wait-for-event.sh"
if ! bash "$WAIT_SCRIPT" "$SESSION_ID" session_start 30 > /dev/null; then
  echo "Error: Worker session failed to start within 30 seconds" >&2
  transport_exec tmux kill-session -t "$TMUX_NAME" 2>/dev/null || true
  rm -f "/tmp/claude-workers/${SESSION_ID}.meta" "/tmp/claude-workers/${SESSION_ID}.events.jsonl"
  exit 1
fi

jq -n \
  --arg session_id "$SESSION_ID" \
  --arg tmux_name "$TMUX_NAME" \
  --arg events_file "/tmp/claude-workers/${SESSION_ID}.events.jsonl" \
  '{session_id: $session_id, tmux_name: $tmux_name, events_file: $events_file}'
