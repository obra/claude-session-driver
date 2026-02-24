#!/usr/bin/env bash
# lib/transport.sh — transport abstraction for claude-session-driver
# Source this file; do not execute directly.
# Not using set -euo pipefail — this file is sourced; callers control error handling.

# Internal helper: run ssh with shared ControlMaster options.
_csd_ssh() {
  local host="$1"; shift
  ssh -o ControlMaster=auto \
      -o ControlPath="$HOME/.ssh/csd-%r@%h:%p" \
      -o ControlPersist=60 \
      "$host" "$@"
}

# Load target from session .meta file into WORKER_TARGET env var.
csd_load_target() {
  local session_id="$1"
  local meta_file="/tmp/claude-workers/${session_id}.meta"
  WORKER_TARGET="${WORKER_TARGET:-local}"
  export WORKER_TARGET
  if [ -f "$meta_file" ]; then
    WORKER_TARGET=$(jq -r '.target // "local"' "$meta_file")
    export WORKER_TARGET
  else
    echo "transport: warning: no .meta file for session $session_id, using local transport" >&2
  fi
}

# Run a command via the configured transport.
transport_exec() {
  local target="${WORKER_TARGET:-local}"
  case "$target" in
    local|"") "$@" ;;
    ssh://*)
      local host="${target#ssh://}"
      local args=()
      for arg in "$@"; do args+=("$(printf '%q' "$arg")"); done
      _csd_ssh "$host" "${args[*]}"
      ;;
    docker://*)
      local container="${target#docker://}"
      docker exec "$container" "$@"
      ;;
    *)
      echo "transport: unknown target: $target" >&2
      return 1
      ;;
  esac
}

# Read a remote file (cat equivalent).
transport_read() {
  local target="${WORKER_TARGET:-local}"
  local filepath="$1"
  case "$target" in
    local|"")   cat "$filepath" ;;
    ssh://*)    _csd_ssh "${target#ssh://}" "cat $(printf '%q' "$filepath")" ;;
    docker://*) docker exec "${target#docker://}" cat "$filepath" ;;
    *)          echo "transport: unknown target: $target" >&2; return 1 ;;
  esac
}

# Tail a remote file (tail -f equivalent).
transport_tail() {
  local target="${WORKER_TARGET:-local}"
  local filepath="$1"
  case "$target" in
    local|"")   tail -f "$filepath" ;;
    ssh://*)
      local host="${target#ssh://}"
      ssh -tt -o ControlMaster=auto \
          -o ControlPath="$HOME/.ssh/csd-%r@%h:%p" \
          -o ControlPersist=60 \
          "$host" "tail -f $(printf '%q' "$filepath")" ;;
    docker://*) docker exec "${target#docker://}" tail -f "$filepath" ;;
    *)          echo "transport: unknown target: $target" >&2; return 1 ;;
  esac
}

# Write content to a remote file.
transport_write() {
  local target="${WORKER_TARGET:-local}"
  local content="$1"
  local filepath="$2"
  case "$target" in
    local|"")
      printf '%s' "$content" > "$filepath"
      ;;
    ssh://*)
      printf '%s' "$content" | _csd_ssh "${target#ssh://}" "cat > $(printf '%q' "$filepath")"
      ;;
    docker://*)
      local container="${target#docker://}"
      printf '%s' "$content" | docker exec -i "$container" sh -c "cat > $(printf '%q' "$filepath")"
      ;;
    *)
      echo "transport: unknown target: $target" >&2; return 1
      ;;
  esac
}
