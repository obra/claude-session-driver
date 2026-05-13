#!/bin/bash
set -euo pipefail

# Prints the session_id of the most recently launched worker. Useful in
# one-worker workflows where the controller doesn't need to track the UUID
# explicitly — `current.sh` looks it up from /tmp/claude-workers/*.meta.
#
# Exits non-zero with no output to stdout if no workers exist.
#
# Usage: current.sh

WORKER_DIR=/tmp/claude-workers
LATEST=$(ls -t "$WORKER_DIR"/*.meta 2>/dev/null | head -1)

if [ -z "$LATEST" ]; then
  echo "No workers found" >&2
  exit 1
fi

jq -r '.session_id' "$LATEST"
