#!/bin/bash
set -euo pipefail

# Interactive one-time consent flow for claude-session-driver.
#
# Launching workers requires running them with --dangerously-skip-permissions.
# The plugin's PreToolUse hook intercepts each tool call for controller-based
# approval, but the worker still starts in bypass mode and the user should
# affirmatively accept that once. After acceptance, a dotfile is written to
# ~/.claude/.claude-session-driver-consent and launch-worker.sh stops asking.
#
# This script must be run interactively (from a real terminal). The intended
# use case for launch-worker.sh is invocation from inside another claude
# session via the Bash tool — stdin there is not a TTY, so the prompt can't
# happen there. Run this script once per machine; thereafter, launch-worker
# proceeds without prompting.
#
# Usage: bash grant-consent.sh

CONSENT_FILE="$HOME/.claude/.claude-session-driver-consent"

if [ -f "$CONSENT_FILE" ]; then
  echo "Consent already on file at $CONSENT_FILE"
  echo "Nothing to do. Delete that file if you want to re-grant consent."
  exit 0
fi

if [ ! -t 0 ] || [ ! -t 1 ]; then
  cat >&2 <<EOF
Error: grant-consent.sh must be run from an interactive terminal.

This script asks you a yes/no question about whether you accept the plugin's
use of --dangerously-skip-permissions. It can't run when stdin or stdout is
piped or redirected.

Open a real terminal and run:
    bash $0
EOF
  exit 1
fi

cat <<EOF

claude-session-driver — one-time consent
========================================

This plugin spawns Claude Code workers with --dangerously-skip-permissions.

Workers will not display the normal permission dialog before each tool call.
Instead, the plugin's PreToolUse hook routes every tool call back to the
controller (the Claude session that launched the worker) for approval, so the
safety check is still present — just delegated to the controller rather than
shown as an interactive dialog inside the worker.

The controller approves or denies each tool call before the worker runs it.
That approval can come from another Claude session (for project-manager-style
delegation), an automation script, or you typing into a controller terminal.

By proceeding, you accept responsibility for actions the controller approves
on the worker's behalf. This consent is recorded in

    $CONSENT_FILE

and you will not be asked again. To revoke consent, delete that file.

EOF

printf 'Type "yes" to accept and continue: '
read -r CONSENT_REPLY

case "$CONSENT_REPLY" in
  yes|YES|Yes)
    mkdir -p "$(dirname "$CONSENT_FILE")"
    printf 'Consent granted at %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" > "$CONSENT_FILE"
    echo ""
    echo "Consent recorded. You can now launch workers from any context"
    echo "(including the Bash tool inside another Claude session)."
    ;;
  *)
    echo ""
    echo "Consent not granted. No file was written. Re-run this script when"
    echo "you're ready to accept."
    exit 1
    ;;
esac
