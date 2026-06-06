#!/bin/bash
set -euo pipefail
# Real-codex end-to-end smoke: drives an actual Codex worker through csd.
# Gated — costs a real subscription turn. Needs ~/.codex/auth.json + consent.
#   CSD_RUN_REAL_CODEX=1 bash tests/smoke-codex-real.sh
[ -n "${CSD_RUN_REAL_CODEX:-}" ] || { echo "Set CSD_RUN_REAL_CODEX=1 to run (uses a real codex subscription turn)."; exit 0; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CSD="$SCRIPT_DIR/../skills/driving-claude-code-sessions/scripts/csd"
# Self-contained HOME: staged consent + a copy of the real codex auth, so the
# smoke doesn't require `csd grant-consent` and never touches the real ~/.claude.
REAL_CODEX_AUTH="$HOME/.codex/auth.json"
SHOME=$(mktemp -d); mkdir -p "$SHOME/.claude" "$SHOME/.codex"
touch "$SHOME/.claude/.claude-session-driver-consent"
[ -f "$REAL_CODEX_AUTH" ] && cp "$REAL_CODEX_AUTH" "$SHOME/.codex/auth.json"
export HOME="$SHOME"
WDIR=$(mktemp -d); WD=$(mktemp -d); TN="smoke-codex-$$"
export CSD_WORKER_DIR="$WDIR"
cleanup(){ "$CSD" --worker "$TN" stop >/dev/null 2>&1 || true; tmux kill-session -t "$TN" 2>/dev/null || true; rm -rf "$WDIR" "$WD" "$SHOME"; }
trap cleanup EXIT

echo "[smoke] launching real codex worker $TN in $WD ..."
SHIM=$("$CSD" launch --harness codex "$TN" "$WD")
echo "[smoke] shim: $SHIM"

echo "[smoke] conversing (real turn) ..."
OUT=$("$CSD" --worker "$TN" converse "Run the bash command: echo SMOKE_OK_CODEX . Then reply with exactly the word DONE." 240)
echo "[smoke] === converse response ==="
echo "$OUT"
echo "[smoke] === read-turn ==="
"$CSD" --worker "$TN" read-turn || true

if echo "$OUT" | grep -qiE 'done|smoke_ok'; then
  echo "[smoke] PASS — real Codex worker drove a turn through csd"
else
  echo "[smoke] FAIL — unexpected response"; exit 1
fi
