#!/bin/bash
set -euo pipefail

# Sends a prompt to a Claude Code worker session running in tmux.
# Uses tmux's native load-buffer/paste-buffer for atomic paste of large prompts,
# avoiding the race condition where send-keys -l hasn't finished rendering
# before Enter fires.
#
# For prompts above LARGE_PROMPT_THRESHOLD (50 KiB), automatically switches to
# the FILE-POINTER pattern: instead of pasting the prompt body, sends a short
# directive instructing the worker to Read the prompt file in full. Reason:
# Claude Code's TUI silently rejects pastes above ~50KB-100KB with a "paste
# again to expand" UI prompt; the worker either receives only the tail of the
# buffer or nothing usable. Symptom seen in production: a 235KB prompt landed
# with "first line starts mid-word (tegration), looks like a paste truncation".
#
# Usage: send-prompt.sh <tmux-name> <prompt-text>
#        send-prompt.sh <tmux-name> --file <path>
#
# The --file form reads the prompt from a path. Use this for prompts >128KB
# (Linux MAX_ARG_STRLEN per-arg limit; ARG_MAX-style failures present as
# bash exit 126 with truncated "Argument list too long" message).
#
# Behavior: prompts larger than ${LARGE_PROMPT_THRESHOLD} bytes (default 51200 = 50 KiB)
# deliver as a file-pointer directive ("Read <abs-path> in full ...") instead of
# inline paste. Override the threshold via env: LARGE_PROMPT_THRESHOLD=N. For the
# file-pointer path the prompt path MUST be absolute (mktemp output is absolute;
# explicit --file paths must be absolute too — exit 2 on relative paths).

# Threshold for switching from inline paste to file-pointer pattern. 50 KiB is
# conservative — observed paste-truncation kicks in around 50-100KB depending
# on Claude Code TUI version; staying well under the lower bound is safe.
LARGE_PROMPT_THRESHOLD="${LARGE_PROMPT_THRESHOLD:-51200}"

TMUX_NAME="${1:?Usage: send-prompt.sh <tmux-name> <prompt-text> | --file <path>}"
shift || true

if [ "${1:-}" = "--file" ]; then
  PROMPT_FILE="${2:?Usage: send-prompt.sh <tmux-name> --file <path>}"
  if [ ! -f "$PROMPT_FILE" ]; then
    echo "Error: prompt file '$PROMPT_FILE' does not exist" >&2
    exit 2
  fi
  TMPFILE="$PROMPT_FILE"
  CLEANUP_TMPFILE=false
else
  PROMPT_TEXT="${1:?Usage: send-prompt.sh <tmux-name> <prompt-text> | --file <path>}"
  TMPFILE=$(mktemp /tmp/claude-prompt-XXXXXX)
  printf '%s' "$PROMPT_TEXT" > "$TMPFILE"
  CLEANUP_TMPFILE=true
fi

# Verify tmux session exists
if ! tmux has-session -t "$TMUX_NAME" 2>/dev/null; then
  echo "Error: tmux session '$TMUX_NAME' does not exist" >&2
  [ "$CLEANUP_TMPFILE" = "true" ] && rm -f "$TMPFILE"
  exit 1
fi

# Detect prompt size and pick delivery strategy.
# Fail loud if size cannot be determined — falling back silently to "small" would
# recreate the original paste-truncation bug for any prompt the script is being
# called on; the fallback chain MUST be silent-regression-safe.
if PROMPT_SIZE=$(stat -c %s "$TMPFILE" 2>/dev/null); then
  :
elif PROMPT_SIZE=$(stat -f %z "$TMPFILE" 2>/dev/null); then
  :
else
  echo "Error: cannot determine prompt size for '$TMPFILE' (no compatible stat); refusing to send (would risk silent paste-truncation regression for large prompts)" >&2
  [ "$CLEANUP_TMPFILE" = "true" ] && rm -f "$TMPFILE"
  exit 2
fi

if [ "$PROMPT_SIZE" -gt "$LARGE_PROMPT_THRESHOLD" ]; then
  # File-pointer pattern: paste a short directive instead of the prompt body.
  # The worker reads TMPFILE directly via the Read tool, bypassing the TUI
  # paste-truncation.
  #
  # The worker's CWD may differ from this script's CWD, so the path the worker
  # reads MUST be absolute. mktemp's output (used in inline mode) is absolute;
  # explicit --file callers must pass absolute paths. Refuse to send a relative
  # path — silently passing one would produce a worker that can't find the file,
  # which is the SAME outward symptom as the original paste-truncation bug.
  case "$TMPFILE" in
    /*)
      ABS_TMPFILE="$TMPFILE"
      ;;
    *)
      echo "Error: prompt path must be absolute for >${LARGE_PROMPT_THRESHOLD}-byte delivery (got: '$TMPFILE'); the worker's Read tool cannot resolve relative paths from its own CWD" >&2
      [ "$CLEANUP_TMPFILE" = "true" ] && rm -f "$TMPFILE"
      exit 2
      ;;
  esac

  # TMPFILE must remain on disk until the worker reads it, so the cleanup we
  # otherwise do for inline-mode tmpfiles is deferred. Schedule a background
  # GC after 1 hour to bound the leak — workers should consume the file in
  # seconds, but a crashed worker should not leak the tmpfile indefinitely.
  CLEANUP_TMPFILE=false
  if [ "${TMPFILE#/tmp/claude-prompt-}" != "$TMPFILE" ]; then
    # Only auto-GC tmpfiles we created (mktemp pattern). Caller-owned --file
    # paths are caller-managed.
    ( sleep 3600 && rm -f "$TMPFILE" ) >/dev/null 2>&1 &
    disown >/dev/null 2>&1 || true
  fi

  PASTE_FILE=$(mktemp /tmp/claude-directive-XXXXXX)
  printf 'Read %s in full and execute it as the agent specified at the top of that file. The file is your complete system prompt — do not skim, do not summarize. Follow the file'\''s output contract verbatim, including any output-file or marker-file writes the contract requires.\n' "$ABS_TMPFILE" > "$PASTE_FILE"
else
  PASTE_FILE="$TMPFILE"
fi

# Load prompt into tmux buffer, paste atomically
tmux load-buffer -b prompt-buf "$PASTE_FILE"
tmux paste-buffer -b prompt-buf -t "$TMUX_NAME" -d
[ "$PASTE_FILE" != "$TMPFILE" ] && rm -f "$PASTE_FILE"
[ "$CLEANUP_TMPFILE" = "true" ] && rm -f "$TMPFILE"

# Brief settle time for the pasted text to render in Claude Code's input
sleep 0.5

# Submit
tmux send-keys -t "$TMUX_NAME" Enter
