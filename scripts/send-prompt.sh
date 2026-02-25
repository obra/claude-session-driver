#!/bin/bash
set -euo pipefail

# Sends a prompt to a Claude Code worker session running in tmux.
# Uses literal mode (-l) to prevent tmux from interpreting prompt content as key names.
#
# Usage: send-prompt.sh <tmux-name> <prompt-text>

resolve_tmux_name() {
  local requested="$1"

  if tmux has-session -t "$requested" 2>/dev/null; then
    printf '%s\n' "$requested"
    return 0
  fi

  local meta_file resolved candidate=""
  local match_count=0
  while IFS= read -r meta_file; do
    resolved="$(jq -r --arg requested "$requested" 'select(.requested_tmux_name == $requested) | .tmux_name // empty' "$meta_file" 2>/dev/null || true)"
    if [ -z "$resolved" ]; then
      continue
    fi

    if tmux has-session -t "$resolved" 2>/dev/null; then
      candidate="$resolved"
      match_count=$((match_count + 1))
    fi
  done < <(find /tmp/claude-workers -maxdepth 1 -type f -name '*.meta' 2>/dev/null | sort)

  if [ "$match_count" -eq 1 ]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  printf '%s\n' "$requested"
}

TMUX_NAME_INPUT="${1:?Usage: send-prompt.sh <tmux-name> <prompt-text>}"
PROMPT_TEXT="${2:?Usage: send-prompt.sh <tmux-name> <prompt-text>}"
TMUX_NAME="$(resolve_tmux_name "$TMUX_NAME_INPUT")"

# Verify tmux session exists
if ! tmux has-session -t "$TMUX_NAME" 2>/dev/null; then
  if [ "$TMUX_NAME" != "$TMUX_NAME_INPUT" ]; then
    echo "Error: tmux session '$TMUX_NAME_INPUT' resolved to '$TMUX_NAME', but neither exists" >&2
  else
    echo "Error: tmux session '$TMUX_NAME' does not exist" >&2
  fi
  exit 1
fi

# Send prompt text literally (no tmux key interpretation)
tmux send-keys -t "$TMUX_NAME" -l "$PROMPT_TEXT"

# Send Enter separately
tmux send-keys -t "$TMUX_NAME" Enter
