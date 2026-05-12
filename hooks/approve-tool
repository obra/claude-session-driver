#!/bin/bash
set -euo pipefail

# PreToolUse hook: emits a pre_tool_use event and gives the controller a chance
# to approve or deny the tool call. If the controller doesn't respond within the
# timeout, auto-approves so the worker never hangs.
#
# Only activates for worker sessions launched by the session driver (identified
# by the presence of a .meta file). Non-worker sessions are auto-approved
# immediately to avoid a 30-second polling delay on every tool call.
#
# Flow:
# 1. Read tool details from stdin
# 2. Check if this is a managed worker session (has .meta file)
# 3. If not a worker, auto-approve immediately
# 4. Append pre_tool_use event to the event stream
# 5. Write tool details to <session_id>.tool-pending
# 6. Poll for <session_id>.tool-decision (controller writes this)
# 7. Return the decision (or auto-approve on timeout)
# 8. Clean up pending/decision files

APPROVAL_TIMEOUT="${CLAUDE_SESSION_DRIVER_APPROVAL_TIMEOUT:-30}"

# Read all of stdin with a bounded 5s timeout. Without the timeout, if the
# caller fails to close stdin, the read would hang forever, leaking bash
# processes on every tool call and eventually exhausting the user's process
# limit (issue #9). `read -d ''` reads until NUL; since the JSON payload has
# none, this captures everything up to EOF or timeout in one call, including
# payloads with no trailing newline (which the previous line-by-line loop
# silently dropped, causing the PreToolUse hook to return no
# permissionDecision and inadvertently auto-approve every tool call).
INPUT=""
IFS= read -t 5 -d '' -r INPUT || true

# Empty or unparseable input — caller is misbehaving or stdin was truncated.
# Fail closed: emit an explicit deny so a worker running with
# --dangerously-skip-permissions doesn't auto-approve the tool call when our
# gate is missing. The `jq -e . >/dev/null` guard runs the parse in a
# condition (set -e doesn't fire) so a truncated/partial payload here exits
# via the deny path rather than aborting silently in the jq below.
if [ -z "$INPUT" ] || ! printf '%s' "$INPUT" | jq -e . >/dev/null 2>&1; then
  echo '{"hookSpecificOutput":{"permissionDecision":"deny","permissionDecisionReason":"claude-session-driver PreToolUse hook received no parseable stdin payload"}}'
  exit 0
fi

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id')

# Only activate for managed worker sessions. The session driver creates a .meta
# file when launching a worker. If it doesn't exist, this is a normal interactive
# session (or a --dangerously-skip-permissions session without a controller) and
# we should not block.
if [ ! -f "/tmp/claude-workers/${SESSION_ID}.meta" ]; then
  exit 0
fi

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name')
TOOL_INPUT=$(echo "$INPUT" | jq -c '.tool_input // {}')

PENDING_FILE="/tmp/claude-workers/${SESSION_ID}.tool-pending"
DECISION_FILE="/tmp/claude-workers/${SESSION_ID}.tool-decision"
EVENT_FILE="/tmp/claude-workers/${SESSION_ID}.events.jsonl"

# Ensure directory exists
mkdir -p /tmp/claude-workers

# Emit pre_tool_use event to the event stream
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
jq -cn --arg ts "$TIMESTAMP" --arg event "pre_tool_use" --arg tool "$TOOL_NAME" --arg input "$TOOL_INPUT" \
  '{ts: $ts, event: $event, tool: $tool, tool_input: ($input | fromjson)}' >> "$EVENT_FILE"

# Write pending approval request
jq -cn --arg tool "$TOOL_NAME" --arg input "$TOOL_INPUT" \
  '{tool_name: $tool, tool_input: ($input | fromjson)}' > "$PENDING_FILE"

# Clean up any stale decision file
rm -f "$DECISION_FILE"

# Poll for controller decision
DEADLINE=$((SECONDS + APPROVAL_TIMEOUT))
DECISION="allow"

while [ "$SECONDS" -lt "$DEADLINE" ]; do
  if [ -f "$DECISION_FILE" ]; then
    DECISION=$(jq -r '.decision // "allow"' "$DECISION_FILE" 2>/dev/null)
    break
  fi
  sleep 0.5
done

# Clean up
rm -f "$PENDING_FILE" "$DECISION_FILE"

# Map decision to hook output
case "$DECISION" in
  allow)
    echo '{"hookSpecificOutput":{"permissionDecision":"allow"}}'
    ;;
  deny)
    echo '{"hookSpecificOutput":{"permissionDecision":"deny"}}'
    ;;
  *)
    # Unknown decision, default to allow
    echo '{"hookSpecificOutput":{"permissionDecision":"allow"}}'
    ;;
esac
