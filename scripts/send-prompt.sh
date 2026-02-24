#!/bin/bash
set -euo pipefail

TMUX_NAME="${1:?Usage: send-prompt.sh <tmux-name> <session-id> <prompt-text>}"
SESSION_ID="${2:?Usage: send-prompt.sh <tmux-name> <session-id> <prompt-text>}"
PROMPT_TEXT="${3:?Usage: send-prompt.sh <tmux-name> <session-id> <prompt-text>}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/lib"
# shellcheck source=lib/transport.sh
source "$LIB_DIR/transport.sh"

csd_load_target "$SESSION_ID"

if ! transport_exec tmux has-session -t "$TMUX_NAME" 2>/dev/null; then
  echo "Error: tmux session '$TMUX_NAME' does not exist" >&2
  exit 1
fi

transport_exec tmux send-keys -t "$TMUX_NAME" -l "$PROMPT_TEXT"
transport_exec tmux send-keys -t "$TMUX_NAME" Enter
