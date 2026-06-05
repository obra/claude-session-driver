#!/bin/bash
set -euo pipefail

# Tests for worker provider/auth environment handling (issue #18).
#
# Claude Code's provider selector reads CLAUDE_CODE_USE_BEDROCK / _VERTEX /
# _FOUNDRY / _ANTHROPIC_AWS / _MANTLE directly from the environment (function
# Zq() in the binary), and host-brokered auth keys off
# CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST. A new tmux session inherits the tmux
# SERVER's global environment, which can carry a stale CLAUDE_CODE_USE_BEDROCK
# from an earlier session and hijack the worker's provider (-> Bedrock 403).
#
# csd's rule (clear stale, never force):
#   - CLAUDE_CODE_SSE_PORT          : always pinned empty (IDE-only)
#   - the provider-selector vars +  : pinned empty ONLY when absent from the
#     PROVIDER_MANAGED_BY_HOST         controller (csd's) env, so a stale
#                                     tmux-global value can't leak in; when the
#                                     controller has the var it is left to
#                                     inherit, alongside its credentials.
#
# Strategy: a stub `claude` dumps the provider/auth env it actually received to
# /tmp/csd-workers/<sid>.env-dump. We launch with controlled controller env
# and a deliberately-polluted tmux global env, then inspect the dump.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CSD="$SCRIPT_DIR/../skills/driving-claude-code-sessions/scripts/csd"
WDIR=/tmp/csd-workers

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "  PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "  FAIL: $1 - ${2:-}"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# --- Save/restore tmux server-global vars we mutate, so we never clobber a
# --- developer's pre-existing tmux configuration.
# Parallel indexed arrays (bash 3.2 has no associative arrays).
GLOBALS=(CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST)
GLOBAL_ORIG=()
snapshot_globals() {
  local i v line
  for i in "${!GLOBALS[@]}"; do
    v="${GLOBALS[$i]}"
    if line=$(tmux show-environment -g "$v" 2>/dev/null); then
      GLOBAL_ORIG[$i]="$line"   # "VAR=value" or "-VAR" (hidden marker)
    else
      GLOBAL_ORIG[$i]="__ABSENT__"
    fi
  done
}
restore_globals() {
  local i v orig
  for i in "${!GLOBALS[@]}"; do
    v="${GLOBALS[$i]}"
    orig="${GLOBAL_ORIG[$i]:-__ABSENT__}"
    case "$orig" in
      __ABSENT__|-*) tmux set-environment -g -u "$v" 2>/dev/null || true ;;
      *=*)           tmux set-environment -g "$v" "${orig#*=}" 2>/dev/null || true ;;
    esac
  done
}

FAKE_HOME=$(mktemp -d)
FAKE_CLAUDE=$(mktemp)
NAMES=()
cleanup() {
  local n meta sid
  for n in "${NAMES[@]:-}"; do
    [ -n "$n" ] && tmux kill-session -t "$n" 2>/dev/null || true
  done
  restore_globals
  rm -rf "$FAKE_HOME"
  rm -f "$FAKE_CLAUDE"
  for n in "${NAMES[@]:-}"; do
    [ -n "$n" ] || continue
    meta=$(grep -l "$n" "$WDIR"/*.meta 2>/dev/null | head -1)
    if [ -n "$meta" ]; then
      sid=$(jq -r '.session_id' "$meta" 2>/dev/null || echo "")
      [ -n "$sid" ] && rm -f "$WDIR/$sid".* "$WDIR/$sid.env-dump"
    fi
    rm -f "$WDIR/bin/$n"
  done
}
trap cleanup EXIT
snapshot_globals
mkdir -p "$WDIR" "$WDIR/bin" "$FAKE_HOME/.claude"
touch "$FAKE_HOME/.claude/.claude-session-driver-consent"

# Stub claude: dump the provider/auth env it received, then emit session_start.
cat > "$FAKE_CLAUDE" <<'BASH'
#!/bin/bash
SID=""
while [ $# -gt 0 ]; do case "$1" in --session-id) SID="$2"; shift 2 ;; *) shift ;; esac; done
mkdir -p /tmp/csd-workers
{
  for v in CLAUDE_CODE_SSE_PORT CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST \
           CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY \
           CLAUDE_CODE_USE_ANTHROPIC_AWS CLAUDE_CODE_USE_MANTLE; do
    if val=$(printenv "$v"); then printf '%s=[%s]\n' "$v" "$val"; else printf '%s=UNSET\n' "$v"; fi
  done
} > "/tmp/csd-workers/${SID}.env-dump"
echo "{\"ts\":\"$(date -u +%FT%TZ)\",\"event\":\"session_start\",\"cwd\":\"$PWD\"}" \
  > "/tmp/csd-workers/${SID}.events.jsonl"
exec sleep 60
BASH
chmod +x "$FAKE_CLAUDE"

# Unset every cluster var from the test runner's own env, so each case starts
# from a known-clean controller env and only sets what it means to test.
BASE=(env -u CLAUDE_CODE_SSE_PORT -u CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST \
      -u CLAUDE_CODE_USE_BEDROCK -u CLAUDE_CODE_USE_VERTEX -u CLAUDE_CODE_USE_FOUNDRY \
      -u CLAUDE_CODE_USE_ANTHROPIC_AWS -u CLAUDE_CODE_USE_MANTLE \
      CSD_CLAUDE_BIN="$FAKE_CLAUDE" HOME="$FAKE_HOME")

dump_for() {  # $1 = tmux name -> prints the worker's env dump
  local meta sid
  meta=$(grep -l "$1" "$WDIR"/*.meta 2>/dev/null | head -1)
  [ -n "$meta" ] || { echo "NO-META"; return; }
  sid=$(jq -r '.session_id' "$meta")
  cat "$WDIR/$sid.env-dump" 2>/dev/null || echo "NO-DUMP"
}

# --- 1. SSE_PORT is always pinned empty, even if the controller has one ------
N="test-prov-sse-$$"; NAMES+=("$N")
"${BASE[@]}" CLAUDE_CODE_SSE_PORT=55555 \
  bash "$CSD" launch "$N" /tmp >/dev/null 2>&1
D=$(dump_for "$N")
echo "$D" | grep -qx 'CLAUDE_CODE_SSE_PORT=\[\]' \
  && pass "SSE_PORT pinned empty despite controller value" \
  || fail "sse cleared" "$D"

# --- 2. Stale tmux-global USE_BEDROCK overridden when controller lacks it ----
# This is the actual #18 failure: a leftover global var hijacking the provider.
tmux set-environment -g CLAUDE_CODE_USE_BEDROCK 1
N="test-prov-stale-$$"; NAMES+=("$N")
"${BASE[@]}" bash "$CSD" launch "$N" /tmp >/dev/null 2>&1
D=$(dump_for "$N")
echo "$D" | grep -qx 'CLAUDE_CODE_USE_BEDROCK=\[\]' \
  && pass "stale tmux-global USE_BEDROCK overridden to empty" \
  || fail "stale bedrock cleared" "$D"

# --- 3. Stale tmux-global PROVIDER_MANAGED_BY_HOST cleared when controller lacks it
tmux set-environment -g CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST 1
N="test-prov-stalehost-$$"; NAMES+=("$N")
"${BASE[@]}" bash "$CSD" launch "$N" /tmp >/dev/null 2>&1
D=$(dump_for "$N")
echo "$D" | grep -qx 'CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST=\[\]' \
  && pass "stale tmux-global managed-by-host overridden to empty" \
  || fail "stale host cleared" "$D"

# --- 4. Host-managed flag is NOT clobbered when the controller has it --------
# (controller brokered AND tmux server carries the brokered env): the worker
# must inherit it so host-brokered auth survives, alongside its token.
tmux set-environment -g CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST 1
N="test-prov-keephost-$$"; NAMES+=("$N")
"${BASE[@]}" CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST=1 \
  bash "$CSD" launch "$N" /tmp >/dev/null 2>&1
D=$(dump_for "$N")
echo "$D" | grep -qx 'CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST=\[1\]' \
  && pass "host-managed flag inherited when controller has it" \
  || fail "managed-by-host inherit" "$D"

# --- 5. An intentional Bedrock controller is NOT clobbered -------------------
# (controller wants Bedrock AND the tmux env carries it): worker keeps Bedrock.
tmux set-environment -g CLAUDE_CODE_USE_BEDROCK 1
N="test-prov-keepbedrock-$$"; NAMES+=("$N")
"${BASE[@]}" CLAUDE_CODE_USE_BEDROCK=1 \
  bash "$CSD" launch "$N" /tmp >/dev/null 2>&1
D=$(dump_for "$N")
echo "$D" | grep -qx 'CLAUDE_CODE_USE_BEDROCK=\[1\]' \
  && pass "intentional Bedrock controller not clobbered" \
  || fail "bedrock inherit" "$D"

# --- 6. An EMPTY controller var is treated as absent, not "present" ----------
# A user who disables Bedrock by exporting CLAUDE_CODE_USE_BEDROCK= (empty)
# must still get a stale tmux-global =1 overridden. Empty == false, so pin it.
tmux set-environment -g CLAUDE_CODE_USE_BEDROCK 1
N="test-prov-emptyvar-$$"; NAMES+=("$N")
"${BASE[@]}" CLAUDE_CODE_USE_BEDROCK= \
  bash "$CSD" launch "$N" /tmp >/dev/null 2>&1
D=$(dump_for "$N")
echo "$D" | grep -qx 'CLAUDE_CODE_USE_BEDROCK=\[\]' \
  && pass "empty controller value overrides stale tmux-global" \
  || fail "empty var cleared" "$D"

TOTAL=$((PASS_COUNT + FAIL_COUNT))
echo ""
echo "Results: $PASS_COUNT/$TOTAL passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
