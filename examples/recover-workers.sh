#!/bin/bash
set -euo pipefail

# recover-workers.sh — reference implementation of bulk worker recovery after a
# reboot, built on `csd adopt`.
#
# THE PROBLEM
#   Worker runtime state (the meta/events/shim files under /tmp/claude-workers)
#   lives in /tmp, which macOS clears on reboot. The tmux panes die too. But the
#   *conversations* survive: Claude Code persists every session transcript under
#   ~/.claude/projects/<encoded-cwd>/<session-id>.jsonl. `csd adopt` can bring a
#   transcript back as a live, driveable worker via `claude --resume`. This
#   script finds each worker's transcript and calls `csd adopt` for it.
#
# WHERE THE WORKER LIST COMES FROM
#   --snapshot FILE : a tmux-resurrect save file (e.g. the one tmux-continuum
#                     wrote before the reboot, typically under
#                     ~/.local/share/tmux/resurrect/ or ~/.tmux/resurrect/).
#                     This is the natural pairing with tmux-continuum's
#                     @continuum-boot: continuum restores your layout, then this
#                     re-adopts each restored pane in place.
#   (default)       : the live tmux server's current sessions.
#
# HOW THE SESSION ID IS FOUND
#   For each (tmux-name, cwd), the cwd is encoded the way Claude Code names its
#   project dirs (every /, . and _ becomes -), and the NEWEST *.jsonl in that
#   dir is taken as the worker's session. This is a heuristic: it assumes one
#   worker per cwd. When two workers shared a cwd, it can't disambiguate — it
#   prints the candidates and skips, so you can pass an explicit manifest line.
#
# SHARED-CWD AMBIGUITY
#   The newest-in-dir heuristic fails when two sessions share a cwd — most
#   commonly the repo root, used by BOTH a worker and your driver/PM session.
#   There the newest transcript is usually the driver's, not the worker's.
#   Pin those explicitly with --manifest: a file of `tmux_name<TAB>session_id`
#   lines (an optional third <TAB>cwd column overrides the derived cwd). Manifest
#   entries always win over auto-derivation. ALWAYS --dry-run first and eyeball
#   the UUIDs before applying.
#
# USAGE
#   recover-workers.sh [--dry-run] [--snapshot FILE] [--manifest FILE] \
#                      [--pattern SUBSTR] [-- extra claude args...]
#
#   --dry-run         : print the `csd adopt` commands instead of running them.
#   --snapshot FILE   : derive the worker list from a tmux-resurrect save file.
#   --manifest FILE   : explicit name->session-id (->cwd) pins; win over derive.
#   --pattern SUBSTR  : only recover workers whose tmux name contains SUBSTR.
#   -- <args>         : forwarded to each `csd adopt` (e.g. -- --model sonnet).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CSD="$SCRIPT_DIR/../skills/driving-claude-code-sessions/scripts/csd"

DRY_RUN=0
SNAPSHOT=""
MANIFEST=""
PATTERN=""
EXTRA=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)  DRY_RUN=1; shift ;;
    --snapshot) SNAPSHOT="${2:?--snapshot needs a file}"; shift 2 ;;
    --manifest) MANIFEST="${2:?--manifest needs a file}"; shift 2 ;;
    --pattern)  PATTERN="${2:?--pattern needs a value}"; shift 2 ;;
    --)         shift; EXTRA=("$@"); break ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$MANIFEST" ] && [ ! -f "$MANIFEST" ] && { echo "Manifest not found: $MANIFEST" >&2; exit 1; }

# manifest_lookup <name> <field:2=session_id|3=cwd> — echoes value or empty.
manifest_lookup() {
  [ -n "$MANIFEST" ] || return 0
  awk -F'\t' -v n="$1" -v f="$2" '$1==n{print $f; exit}' "$MANIFEST"
}

# Claude Code encodes a cwd into its project-dir name by replacing every
# '/', '.' and '_' with '-'. (e.g. /a/b/.claude/c_d -> -a-b--claude-c-d)
encode_cwd() { echo "$1" | sed 's#[/._]#-#g'; }

# Emit "tmux_name<TAB>cwd" lines for the workers to recover.
list_workers() {
  if [ -n "$SNAPSHOT" ]; then
    [ -f "$SNAPSHOT" ] || { echo "Snapshot not found: $SNAPSHOT" >&2; exit 1; }
    # resurrect 'pane' lines are tab-separated; the cwd is the field that
    # starts with ':/'. Print one row per session (first pane wins).
    awk -F'\t' '$1=="pane"{
      for(i=1;i<=NF;i++) if($i ~ /^:\//){ if(!seen[$2]++) print $2"\t"substr($i,2); break }
    }' "$SNAPSHOT"
  else
    tmux list-sessions -F '#{session_name}' 2>/dev/null | while read -r s; do
      cwd=$(tmux display-message -p -t "$s" '#{pane_current_path}' 2>/dev/null || true)
      [ -n "$cwd" ] && printf '%s\t%s\n' "$s" "$cwd"
    done
  fi
}

recovered=0 skipped=0
while IFS=$'\t' read -r name cwd; do
  [ -n "$name" ] || continue
  [ -n "$PATTERN" ] && [[ "$name" != *"$PATTERN"* ]] && continue

  # An explicit manifest cwd (col 3) overrides the derived one.
  m_cwd=$(manifest_lookup "$name" 3)
  [ -n "$m_cwd" ] && cwd="$m_cwd"

  # Session id: manifest pin (col 2) wins; otherwise newest transcript in the
  # cwd's project dir. Pinning is how you handle a cwd shared by >1 session.
  uuid=$(manifest_lookup "$name" 2)
  if [ -z "$uuid" ]; then
    proj="$HOME/.claude/projects/$(encode_cwd "$cwd")"
    if [ ! -d "$proj" ]; then
      echo "SKIP  $name — no transcripts dir for cwd ($cwd)" >&2
      skipped=$((skipped+1)); continue
    fi
    # (avoid mapfile — macOS /bin/bash is 3.2)
    jsonls=()
    while IFS= read -r line; do jsonls+=("$line"); done \
      < <(ls -t "$proj"/*.jsonl 2>/dev/null)
    if [ "${#jsonls[@]}" -eq 0 ]; then
      echo "SKIP  $name — no transcripts in $proj" >&2
      skipped=$((skipped+1)); continue
    fi
    uuid=$(basename "${jsonls[0]}" .jsonl)
    if [ "${#jsonls[@]}" -gt 1 ]; then
      echo "WARN  $name — ${#jsonls[@]} transcripts in cwd; picked newest ($uuid)." \
           "If this cwd is shared by another session, pin via --manifest." >&2
    fi
  fi

  ADOPT=(adopt "$name" "$cwd" "$uuid")
  [ "${#EXTRA[@]}" -gt 0 ] && ADOPT+=(-- "${EXTRA[@]}")

  if [ "$DRY_RUN" -eq 1 ]; then
    printf '%q' "$CSD"; printf ' %q' "${ADOPT[@]}"; printf '\n'
  elif "$CSD" "${ADOPT[@]}" >/dev/null; then
    echo "OK    $name  <-  $uuid"
    recovered=$((recovered+1))
  else
    echo "FAIL  $name  ($uuid)" >&2
    skipped=$((skipped+1))
  fi
done < <(list_workers)

echo "" >&2
echo "recovered: $recovered, skipped: $skipped" >&2
