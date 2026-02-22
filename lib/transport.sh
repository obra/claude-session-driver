#!/usr/bin/env bash
# lib/transport.sh — transport abstraction for claude-session-driver
# Source this file; do not execute directly.

# Load target from session .meta file into WORKER_TARGET env var.
csd_load_target() {
  local session_id="$1"
  local meta_file="/tmp/claude-workers/${session_id}.meta"
  if [ -f "$meta_file" ]; then
    WORKER_TARGET=$(jq -r '.target // "local"' "$meta_file")
    export WORKER_TARGET
  fi
}

# Run a command via the configured transport.
transport_exec() {
  local target="${WORKER_TARGET:-local}"
  case "$target" in
    local|"") "$@" ;;
    ssh://*)
      local host="${target#ssh://}"
      ssh -o ControlMaster=auto \
          -o ControlPath="/tmp/csd-ssh-%r@%h:%p" \
          -o ControlPersist=60 \
          "$host" "$@"
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
    ssh://*)    ssh "${target#ssh://}" cat "$filepath" ;;
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
    ssh://*)    ssh "${target#ssh://}" tail -f "$filepath" ;;
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
      printf '%s' "$content" | ssh "${target#ssh://}" "cat > $(printf '%q' "$filepath")"
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
