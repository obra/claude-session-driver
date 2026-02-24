#!/bin/bash
set -euo pipefail

# Reads the last turn from a worker's session log and formats it as markdown.
# A "turn" is everything after the last user prompt: thinking, tool calls,
# tool results, and text responses.
#
# Usage: read-turn.sh <session-id> [--full]
#
# By default, tool results are truncated to 5 lines. Use --full to show
# complete tool results.

SESSION_ID="${1:?Usage: read-turn.sh <session-id> [--full]}"
FULL_OUTPUT=false
if [ "${2:-}" = "--full" ]; then
  FULL_OUTPUT=true
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/lib"
# shellcheck source=lib/transport.sh
source "$LIB_DIR/transport.sh"
csd_load_target "$SESSION_ID"

META_FILE="/tmp/claude-workers/${SESSION_ID}.meta"

# Resolve session log path
CWD=$(jq -r '.cwd' "$META_FILE" 2>/dev/null)
if [ -z "$CWD" ] || [ "$CWD" = "null" ]; then
  echo "Error: Could not determine working directory from meta file" >&2
  exit 1
fi

if [ "${WORKER_TARGET:-local}" = "local" ] || [ -z "${WORKER_TARGET:-}" ]; then
  if [ -d "$CWD" ]; then
    CWD=$(cd "$CWD" && pwd -P)
  fi
fi

WORKER_HOME=$(jq -r '.worker_home // empty' "$META_FILE" 2>/dev/null || echo "$HOME")
ENCODED_PATH=$(echo "$CWD" | sed 's|/|-|g')
LOG_FILE="$WORKER_HOME/.claude/projects/${ENCODED_PATH}/${SESSION_ID}.jsonl"

if [ "${WORKER_TARGET:-local}" = "local" ] || [ -z "${WORKER_TARGET:-}" ]; then
  [ ! -f "$LOG_FILE" ] && { echo "Error: Session log not found at $LOG_FILE" >&2; exit 1; }
fi

# Find the line number of the last real user prompt.
# Filter out tool_result messages and internal commands (local-command, /exit).
LAST_PROMPT_LINE=$(transport_read "$LOG_FILE" | grep -n '"type":"user"' \
  | grep -v '"tool_result"' \
  | grep -v '<local-command' \
  | grep -v '<command-name>' \
  | tail -1 \
  | cut -d: -f1)

if [ -z "$LAST_PROMPT_LINE" ]; then
  echo "No user prompt found in session log" >&2
  exit 1
fi

# Extract all lines from the last prompt onward, filter to assistant and user
# (tool_result) messages, and format as markdown.
transport_read "$LOG_FILE" | tail -n +"$LAST_PROMPT_LINE" \
  | jq -r --argjson full "$FULL_OUTPUT" '
    # Skip non-conversation messages
    select(.type == "assistant" or .type == "user") |

    if .type == "user" then
      # User messages: show the prompt (string) or tool results (array)
      if (.message.content | type) == "string" then
        # Skip internal commands injected by stop-worker.sh and Claude CLI
        if (.message.content | test("^<(local-command|command-name)")) then
          empty
        else
          "---\n\n**Prompt:** " + .message.content + "\n"
        end
      else
        # Tool results
        .message.content[] |
        select(.type == "tool_result") |
        if .is_error then
          "**Tool Error:**\n```\n" + (.content // "(no output)") + "\n```\n"
        else
          if $full then
            "**Result:**\n```\n" + (.content // "(no output)") + "\n```\n"
          else
            "**Result:**\n```\n" + ((.content // "(no output)") | split("\n") | if length > 5 then (.[0:5] | join("\n")) + "\n... (" + (length | tostring) + " lines total)" else join("\n") end) + "\n```\n"
          end
        end
      end

    elif .type == "assistant" then
      .message.content[] |

      if .type == "thinking" then
        "> **Thinking:** " + (.thinking | split("\n") | join("\n> ")) + "\n"

      elif .type == "text" then
        .text + "\n"

      elif .type == "tool_use" then
        "**Tool: " + .name + "**\n```json\n" + (.input | tostring) + "\n```\n"

      else
        empty
      end

    else
      empty
    end
  ' 2>/dev/null
