#!/bin/bash
set -euo pipefail

SESSION_ID="${1:?Usage: approve-tool.sh <session-id> <allow|deny>}"
DECISION="${2:?Usage: approve-tool.sh <session-id> <allow|deny>}"

[ "$DECISION" != "allow" ] && [ "$DECISION" != "deny" ] && {
  echo "Error: decision must be 'allow' or 'deny'" >&2; exit 1
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/lib"
# shellcheck source=lib/transport.sh
source "$LIB_DIR/transport.sh"
csd_load_target "$SESSION_ID"

DECISION_FILE="/tmp/claude-workers/${SESSION_ID}.tool-decision"
CONTENT=$(jq -cn --arg decision "$DECISION" '{decision: $decision}')

transport_write "$CONTENT" "$DECISION_FILE"
