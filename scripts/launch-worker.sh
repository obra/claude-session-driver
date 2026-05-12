#!/bin/bash
set -euo pipefail

# Launches a Claude Code worker session in a detached tmux session with the
# session-driver plugin loaded for lifecycle event emission.
#
# Usage: launch-worker.sh <tmux-name> <working-dir> [extra claude args...]

TMUX_NAME="${1:?Usage: launch-worker.sh <tmux-name> <working-dir> [extra claude args...]}"
WORKING_DIR="${2:?Usage: launch-worker.sh <tmux-name> <working-dir> [extra claude args...]}"
shift 2
EXTRA_ARGS=("$@")

# Resolve plugin directory (parent of scripts/)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Resolve working directory to absolute physical path (resolves symlinks)
WORKING_DIR="$(cd "$WORKING_DIR" && pwd -P)"

# One-time consent for running workers in --dangerously-skip-permissions mode.
# The interactive prompt lives in scripts/grant-consent.sh so the user can run
# it once from a real terminal. launch-worker.sh itself is typically invoked
# from a non-interactive context (the Bash tool inside another claude session)
# where prompting is impossible — so here we only check the dotfile and bail
# with a clear pointer if it's missing.
CONSENT_FILE="$HOME/.claude/.claude-session-driver-consent"
if [ ! -f "$CONSENT_FILE" ]; then
  cat >&2 <<EOF
Error: claude-session-driver requires one-time consent before launching workers.

This plugin runs workers with --dangerously-skip-permissions and routes
tool-call approval through its PreToolUse hook. You need to acknowledge
that once. Open a terminal and run:

    bash $SCRIPT_DIR/grant-consent.sh

Then retry launch-worker.sh.
EOF
  exit 1
fi

# Generate session ID
SESSION_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')

# Ensure output directory exists
mkdir -p /tmp/claude-workers

# Write metadata
jq -n \
  --arg tmux_name "$TMUX_NAME" \
  --arg session_id "$SESSION_ID" \
  --arg cwd "$WORKING_DIR" \
  --arg started_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  '{tmux_name: $tmux_name, session_id: $session_id, cwd: $cwd, started_at: $started_at}' \
  > "/tmp/claude-workers/${SESSION_ID}.meta"

# Check for existing tmux session with this name
if tmux has-session -t "$TMUX_NAME" 2>/dev/null; then
  echo "Error: tmux session '$TMUX_NAME' already exists" >&2
  rm -f "/tmp/claude-workers/${SESSION_ID}.meta"
  exit 1
fi

# Propagate approval timeout through tmux to the hook environment
APPROVAL_TIMEOUT="${CLAUDE_SESSION_DRIVER_APPROVAL_TIMEOUT:-30}"

# When the controller is itself a claude session (or a Claude Desktop
# Terminal), two env vars can leak into the worker and break it:
#   CLAUDE_CODE_SSE_PORT                 - points the worker at the parent's
#                                          IDE SSE port for VSCode/JetBrains
#                                          integration; the worker has no
#                                          relationship to that IDE
#   CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST - tells the worker its auth is
#                                          managed by a host process that
#                                          doesn't exist for it; breaks auth
#
# `tmux -e VAR=` sets the var to empty rather than unsetting it, but claude
# code uses truthy checks on both of these (parseInt(q) gated by `q?…:null`
# for SSE_PORT, `SH(env.X)` for PROVIDER_MANAGED_BY_HOST), so empty is
# equivalent to unset for our purposes.
#
# --settings populates flagSettings with skipDangerousModePermissionPrompt,
# silencing the bypass-permissions warning. Paired with
# --dangerously-skip-permissions, which the user already consented to.
tmux new-session -d -s "$TMUX_NAME" -c "$WORKING_DIR" \
  -e "CLAUDE_SESSION_DRIVER_APPROVAL_TIMEOUT=$APPROVAL_TIMEOUT" \
  -e "CLAUDE_CODE_SSE_PORT=" \
  -e "CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST=" \
  claude --session-id "$SESSION_ID" --plugin-dir "$PLUGIN_DIR" \
    --settings '{"skipDangerousModePermissionPrompt":true}' \
    --dangerously-skip-permissions \
    "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"

# Content-aware trust-dialog accept. When claude opens in a working directory
# it hasn't trusted before, it shows a "Yes, I trust this folder" / "No, exit"
# dialog with default focus on the confirm (yes) button. Poll the pane briefly
# and send Enter only when we see the trust-dialog signature — leaving other
# blocking screens (theme picker, sign-in, etc.) alone so they surface in the
# timeout error instead of being mis-accepted.
TRUST_DEADLINE=$((SECONDS + 5))
while [ "$SECONDS" -lt "$TRUST_DEADLINE" ]; do
  PANE_TEXT=$(tmux capture-pane -t "$TMUX_NAME" -p 2>/dev/null || true)
  if echo "$PANE_TEXT" | grep -qF "trust this folder"; then
    tmux send-keys -t "$TMUX_NAME" Enter
    break
  fi
  # If session_start has already fired, no dialog appeared at all.
  if [ -f "/tmp/claude-workers/${SESSION_ID}.events.jsonl" ] \
     && grep -q '"event":"session_start"' "/tmp/claude-workers/${SESSION_ID}.events.jsonl" 2>/dev/null; then
    break
  fi
  sleep 0.25
done

# Wait for session to start
WAIT_SCRIPT="$SCRIPT_DIR/wait-for-event.sh"
if ! bash "$WAIT_SCRIPT" "$SESSION_ID" session_start 30 > /dev/null; then
  # || true so we still reach the cleanup below even if the tmux session
  # already exited (capture-pane would otherwise fail under pipefail).
  PANE=$(tmux capture-pane -t "$TMUX_NAME" -p 2>/dev/null | sed -e 's/[[:space:]]*$//' -e '/^$/d' | tail -20 || true)
  {
    echo "Error: Worker session failed to start within 30 seconds"
    if [ -n "$PANE" ]; then
      echo ""
      echo "Last visible content in the worker pane:"
      echo "----------"
      echo "$PANE"
      echo "----------"
      echo ""
      echo "If this looks like an authentication, onboarding, or theme-picker"
      echo "prompt, run \`claude\` once interactively in $WORKING_DIR to"
      echo "complete CLI setup, then retry."
    fi
  } >&2
  tmux kill-session -t "$TMUX_NAME" 2>/dev/null || true
  rm -f "/tmp/claude-workers/${SESSION_ID}.meta" "/tmp/claude-workers/${SESSION_ID}.events.jsonl"
  exit 1
fi

# Output session info
jq -n \
  --arg session_id "$SESSION_ID" \
  --arg tmux_name "$TMUX_NAME" \
  --arg events_file "/tmp/claude-workers/${SESSION_ID}.events.jsonl" \
  '{session_id: $session_id, tmux_name: $tmux_name, events_file: $events_file}'
