#!/bin/bash
set -euo pipefail

# Sends a prompt to a Claude Code worker session running in tmux.
#
# The prompt text is wrapped in bracketed paste markers (\x1B[200~ ... \x1B[201~)
# so the Claude Code TUI processes it through its paste path, which handles
# multi-line content and embedded \r correctly. A 100ms gap follows the
# paste-end marker before Enter is sent, giving the TUI's event loop time to
# exit paste state so the Enter is dispatched as a submit key rather than being
# absorbed into the paste buffer or dropped.
#
# This mirrors the pattern Anthropic's own SDK uses when driving a Claude Code
# TUI through a child pty (which writes `\x1B[200~${text}\x1B[201~` then
# schedules `\r` 10ms later); the larger 100ms gap accounts for tmux jitter.
#
# Usage: send-prompt.sh <tmux-name> <prompt-text>

TMUX_NAME="${1:?Usage: send-prompt.sh <tmux-name> <prompt-text>}"
PROMPT_TEXT="${2:?Usage: send-prompt.sh <tmux-name> <prompt-text>}"

# Verify tmux session exists
if ! tmux has-session -t "$TMUX_NAME" 2>/dev/null; then
  echo "Error: tmux session '$TMUX_NAME' does not exist" >&2
  exit 1
fi

ESC=$'\x1b'
PASTE_START="${ESC}[200~"
PASTE_END="${ESC}[201~"

# Strip any literal paste-end markers from the prompt. If the prompt contained
# one (plausible: docs about terminal escapes, captured session logs), the TUI
# would exit paste state mid-prompt and treat the rest as raw keystrokes —
# which can fire Tab/arrow/Enter shortcuts inside the worker.
SAFE_PROMPT=${PROMPT_TEXT//${PASTE_END}/}
SAFE_PROMPT=${SAFE_PROMPT//${PASTE_START}/}

# Send the prompt wrapped in bracketed-paste markers
tmux send-keys -t "$TMUX_NAME" -l "${PASTE_START}${SAFE_PROMPT}${PASTE_END}"

# Let the TUI exit paste state before Enter arrives
sleep 0.1

# Send Enter to submit
tmux send-keys -t "$TMUX_NAME" Enter
