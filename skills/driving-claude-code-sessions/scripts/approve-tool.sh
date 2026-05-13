#!/bin/bash
set -euo pipefail

# Writes an approval decision for a pending tool call from a worker session.
#
# Usage: approve-tool.sh <session-id-or-tmux-name> <allow|deny>
#
# The first arg may be either a session_id (UUID) or a tmux_name.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"

ID_OR_NAME="${1:?Usage: approve-tool.sh <session-id-or-tmux-name> <allow|deny>}"
DECISION="${2:?Usage: approve-tool.sh <session-id-or-tmux-name> <allow|deny>}"

SESSION_ID=$(resolve_session "$ID_OR_NAME")
DECISION_FILE="/tmp/claude-workers/${SESSION_ID}.tool-decision"

if [ "$DECISION" != "allow" ] && [ "$DECISION" != "deny" ]; then
  echo "Error: decision must be 'allow' or 'deny'" >&2
  exit 1
fi

jq -cn --arg decision "$DECISION" '{decision: $decision}' > "$DECISION_FILE"
