#!/bin/bash
set -euo pipefail
# Real-pi end-to-end multi-turn smoke: drives an actual Pi worker through csd.
# Gated — costs real subscription turns. Needs ~/.pi/agent (auth) + the pi binary.
#   CSD_RUN_REAL_PI=1 bash tests/smoke-pi-real.sh
[ -n "${CSD_RUN_REAL_PI:-}" ] || { echo "Set CSD_RUN_REAL_PI=1 to run (uses real pi subscription turns)."; exit 0; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CSD="$SCRIPT_DIR/../skills/driving-claude-code-sessions/scripts/csd"
REAL_HOME="$HOME"
PI="${CSD_PI_BIN:-$(command -v pi 2>/dev/null || ls "$REAL_HOME"/.local/share/mise/installs/pi/*/pi 2>/dev/null | head -1)}"
[ -n "$PI" ] && [ -x "$PI" ] || { echo "pi binary not found; set CSD_PI_BIN to its path."; exit 0; }

# Self-contained HOME: staged consent + a copy of the real ~/.pi/agent (auth).
SHOME=$(mktemp -d); mkdir -p "$SHOME/.claude" "$SHOME/.pi"
touch "$SHOME/.claude/.claude-session-driver-consent"
[ -d "$REAL_HOME/.pi/agent" ] && cp -R "$REAL_HOME/.pi/agent" "$SHOME/.pi/agent"
export HOME="$SHOME" CSD_PI_BIN="$PI"
WDIR=$(mktemp -d); WD=$(mktemp -d); TN="smoke-pi-$$"
export CSD_WORKER_DIR="$WDIR"
cleanup(){ "$CSD" --worker "$TN" stop >/dev/null 2>&1 || true; tmux kill-session -t "$TN" 2>/dev/null || true; rm -rf "$WDIR" "$WD" "$SHOME"; }
trap cleanup EXIT

echo "[smoke] launching real pi worker $TN ($PI) ..."
SHIM=$("$CSD" launch --harness pi "$TN" "$WD")
echo "[smoke] shim: $SHIM"

echo "[smoke] turn 1 ..."
OUT1=$("$CSD" --worker "$TN" converse "Reply with exactly the word ALPHA and nothing else." 180)
echo "[smoke] turn 1 response: $OUT1"
echo "[smoke] turn 2 (multi-turn — must NOT return turn 1's answer) ..."
OUT2=$("$CSD" --worker "$TN" converse "Reply with exactly the word BRAVO and nothing else." 180)
echo "[smoke] turn 2 response: $OUT2"
echo "[smoke] === read-turn ==="
"$CSD" --worker "$TN" read-turn || true

if echo "$OUT1" | grep -qi 'alpha' && echo "$OUT2" | grep -qi 'bravo' && ! echo "$OUT2" | grep -qi 'alpha'; then
  echo "[smoke] PASS — real Pi multi-turn conversation through csd (turn 2 != stale turn 1)"
else
  echo "[smoke] FAIL — turn1='$OUT1' turn2='$OUT2'"; exit 1
fi
