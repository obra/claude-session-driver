#!/bin/bash
set -euo pipefail

# Sends a prompt to a Claude Code worker session running in tmux.
# Uses literal mode (-l) to prevent tmux from interpreting prompt content as key names.
#
# Usage: send-prompt.sh <tmux-name> <prompt-text> [session-id]

tmux_target_exists() {
  local target="$1"
  tmux list-panes -t "$target" >/dev/null 2>&1
}

resolve_tmux_name() {
  local requested="$1"
  local session_id="${2:-}"

  if [ -n "$session_id" ]; then
    local session_meta_file="/tmp/claude-workers/${session_id}.meta"
    local session_tmux_name=""
    if [ -f "$session_meta_file" ]; then
      session_tmux_name="$(jq -r '.tmux_name // empty' "$session_meta_file" 2>/dev/null || true)"
      if [ -n "$session_tmux_name" ] && tmux_target_exists "$session_tmux_name"; then
        printf '%s\n' "$session_tmux_name"
        return 0
      fi
    fi
  fi

  if tmux_target_exists "$requested"; then
    printf '%s\n' "$requested"
    return 0
  fi

  local meta_file resolved candidate=""
  local match_count=0
  local seen=$'\n'
  while IFS= read -r meta_file; do
    resolved="$(jq -r --arg requested "$requested" 'select(.requested_tmux_name == $requested) | .tmux_name // empty' "$meta_file" 2>/dev/null || true)"
    if [ -z "$resolved" ]; then
      continue
    fi

    if tmux_target_exists "$resolved"; then
      case "$seen" in
        *$'\n'"$resolved"$'\n'*)
          ;;
        *)
          seen+="$resolved"$'\n'
          candidate="$resolved"
          match_count=$((match_count + 1))
          ;;
      esac
    fi
  done < <(find /tmp/claude-workers -maxdepth 1 -type f -name '*.meta' 2>/dev/null | sort)

  if [ "$match_count" -eq 1 ]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  printf '%s\n' "$requested"
}

TMUX_NAME_INPUT="${1:?Usage: send-prompt.sh <tmux-name> <prompt-text> [session-id]}"
PROMPT_TEXT="${2:?Usage: send-prompt.sh <tmux-name> <prompt-text> [session-id]}"
SESSION_ID="${3:-}"
TMUX_NAME="$(resolve_tmux_name "$TMUX_NAME_INPUT" "$SESSION_ID")"

# Verify tmux target exists
if ! tmux_target_exists "$TMUX_NAME"; then
  if [ -n "$SESSION_ID" ]; then
    echo "Error: session '$SESSION_ID' does not map to a running tmux target (resolved '$TMUX_NAME')" >&2
  elif [ "$TMUX_NAME" != "$TMUX_NAME_INPUT" ]; then
    echo "Error: tmux target '$TMUX_NAME_INPUT' resolved to '$TMUX_NAME', but it no longer exists" >&2
  else
    echo "Error: tmux target '$TMUX_NAME' does not exist" >&2
  fi
  exit 1
fi

# Send prompt text literally (no tmux key interpretation)
tmux send-keys -t "$TMUX_NAME" -l "$PROMPT_TEXT"

# Send Enter separately
tmux send-keys -t "$TMUX_NAME" Enter
