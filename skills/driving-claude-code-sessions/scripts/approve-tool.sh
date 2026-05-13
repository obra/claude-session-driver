#!/bin/bash
set -euo pipefail

# Writes an approval decision for a pending tool call from a worker session.
#
# Usage: approve-tool.sh <session-id> <allow|deny>

SESSION_ID="${1:?Usage: approve-tool.sh <session-id> <allow|deny>}"
DECISION="${2:?Usage: approve-tool.sh <session-id> <allow|deny>}"

DECISION_FILE="/tmp/claude-workers/${SESSION_ID}.tool-decision"

if [ "$DECISION" != "allow" ] && [ "$DECISION" != "deny" ]; then
  echo "Error: decision must be 'allow' or 'deny'" >&2
  exit 1
fi

jq -cn --arg decision "$DECISION" '{decision: $decision}' > "$DECISION_FILE"
