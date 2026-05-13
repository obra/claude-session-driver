#!/bin/bash
set -euo pipefail

# Prints a ready-to-paste handoff message for a human to take over a worker.
# Emits the attach command, detach instructions, and a reminder not to stop
# the worker mid-handoff.
#
# Usage: handoff.sh <session-id-or-tmux-name>

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"

ID_OR_NAME="${1:?Usage: handoff.sh <session-id-or-tmux-name>}"
SESSION_ID=$(resolve_session "$ID_OR_NAME")
TMUX_NAME=$(jq -r '.tmux_name' "/tmp/claude-workers/${SESSION_ID}.meta")

cat <<EOF
The worker is running in tmux session '$TMUX_NAME'. To take over:

    tmux attach -t $TMUX_NAME

Once attached, you can type to the worker directly. Detach with Ctrl-B d to
return without ending the session.

Leave the worker running. The controller can resume by sending another
prompt — do not run stop-worker.sh unless you actually want to terminate
the session.
EOF
