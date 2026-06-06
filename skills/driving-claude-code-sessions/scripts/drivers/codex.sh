#!/bin/bash
# Codex (OpenAI) harness driver for csd. Sourced, not executed. derive-id +
# hook control plane. Validated end-to-end against codex 0.134 (spec Appendix B).

harness_id()            { echo "codex"; }
harness_bin()           { echo "${CSD_CODEX_BIN:-codex}"; }
harness_control_plane() { echo "hooks"; }
harness_id_strategy()   { echo "derive"; }
harness_quit_keys()     { echo "/quit"; }

# Per-worker config: a CODEX_HOME holding a config.toml that registers the
# self-registering hook on each lifecycle event, plus project trust. Auth is
# staged (the operator's ~/.codex/auth.json) so the worker authenticates as the
# operator. Reads CSD_PLUGIN_DIR (set by the spine) to locate emit-event-codex.
harness_prepare() {
  local tmux_name="$1" cwd="$2" home="$3"
  local hook="${CSD_PLUGIN_DIR}/hooks/emit-event-codex"
  local model="${CSD_CODEX_MODEL:-gpt-5.5}"
  mkdir -p "$home"
  [ -f "$HOME/.codex/auth.json" ] && cp "$HOME/.codex/auth.json" "$home/" 2>/dev/null || true
  {
    echo "model = \"$model\""
    echo "model_reasoning_effort = \"low\""
    echo "[projects.\"$cwd\"]"
    echo "trust_level = \"trusted\""
    local ev
    for ev in SessionStart UserPromptSubmit PreToolUse PostToolUse Stop SessionEnd; do
      echo "[[hooks.$ev]]"
      case "$ev" in PreToolUse|PostToolUse) echo "matcher = \".*\"" ;; esac
      echo "[[hooks.$ev.hooks]]"
      echo "type = \"command\""
      echo "command = \"$hook $tmux_name $cwd $_CSD_WORKER_DIR\""
    done
  } > "$home/config.toml"
}

# harness_launch_argv <mode> <sid> <cwd> <plugin_dir> <worker_home>
# Codex ignores sid (derive), plugin_dir (hooks via CODEX_HOME), worker_home
# (passed as env). Interactive; -C sets the workdir.
harness_launch_argv() {
  local cwd="$3"
  printf '%s\n' \
    "$(harness_bin)" \
    --dangerously-bypass-approvals-and-sandbox \
    --dangerously-bypass-hook-trust \
    -C "$cwd"
}

# CODEX_HOME points codex at the per-worker config/auth/sessions dir. The spine
# sets _CSD_CURRENT_WORKER_HOME before launch; default-guarded for set -u.
harness_env_args() {
  WORKER_ENV_ARGS=(-e "CODEX_HOME=${_CSD_CURRENT_WORKER_HOME:-}")
}

# Dismiss the "Hooks need review" trust gate (the bypass flag does NOT skip it).
harness_post_launch() {
  local tmux_name="$1" deadline=$((SECONDS + 8)) pane
  while [ "$SECONDS" -lt "$deadline" ]; do
    pane=$(tmux capture-pane -t "$tmux_name" -p 2>/dev/null || true)
    if echo "$pane" | grep -qiE 'hooks need review|trust all|review'; then
      tmux send-keys -t "$tmux_name" -l '2'; sleep 0.3
      tmux send-keys -t "$tmux_name" Enter
      return 0
    fi
    sleep 0.25
  done
}

# derive readiness: session_start fires at the first prompt, not boot. Wait for
# the composer glyph, else settle. The first send re-confirms via self-registration.
harness_await_ready() {
  local tmux_name="$1" deadline=$((SECONDS + 20)) pane
  while [ "$SECONDS" -lt "$deadline" ]; do
    pane=$(tmux capture-pane -t "$tmux_name" -p 2>/dev/null || true)
    echo "$pane" | grep -q '›' && return 0
    sleep 0.5
  done
  return 0
}

# The transcript path is recorded by the self-registering hook; read from meta.
harness_transcript_path() {
  local sid="$1"
  jq -r '.transcript_path // empty' "$_CSD_WORKER_DIR/${sid}.meta" 2>/dev/null
}

# Render the last turn of a codex rollout as markdown.
harness_parse_turn() {
  local rollout="$1"
  [ -f "$rollout" ] || { echo "No rollout at $rollout" >&2; return 1; }
  # Find the last user message line. The grep pipeline can legitimately match
  # nothing (e.g. a tool-only turn); guard against set -e/pipefail aborting here.
  local start=""
  start=$(grep -n '"type":"response_item"' "$rollout" | grep '"role":"user"' | tail -1 | cut -d: -f1) || start=""
  [ -z "$start" ] && start=1
  tail -n +"$start" "$rollout" | jq -r '
    select(.type=="response_item") | .payload as $p |
    if   $p.type=="message" then "**[" + $p.role + "]** " + ([$p.content[]?.text // $p.content[]?.output_text // ""] | join("")) + "\n"
    elif $p.type=="reasoning" then "> **Thinking:** " + (($p.summary // []) | map(.text // .) | join(" ")) + "\n"
    elif $p.type=="function_call" then "**Tool: " + $p.name + "**\n```\n" + ($p.arguments | tostring) + "\n```\n"
    elif $p.type=="function_call_output" then "**Result:**\n```\n" + ($p.output | tostring) + "\n```\n"
    else empty end' 2>/dev/null
}

# Count assistant agent_message records (one value, set -e safe).
harness_count_text() {
  local rollout="$1" c
  [ -f "$rollout" ] || { echo 0; return; }
  c=$(grep -c '"agent_message"' "$rollout" 2>/dev/null) || c=0
  echo "$c"
}

# Last assistant message text.
harness_last_text() {
  local rollout="$1"
  [ -f "$rollout" ] || return 0
  grep '"type":"event_msg"' "$rollout" \
    | jq -rs 'map(select(.payload.type=="agent_message")) | last | .payload.message // ""' 2>/dev/null
}
