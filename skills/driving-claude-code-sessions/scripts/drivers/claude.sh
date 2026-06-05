#!/bin/bash
# Claude Code harness driver for csd. Sourced, not executed. Implements the
# harness slot contract (docs/superpowers/specs/2026-06-05-csd-multiharness-design.md).

harness_id()            { echo "claude"; }
harness_bin()           { echo "${CSD_CLAUDE_BIN:-claude}"; }
harness_control_plane() { echo "hooks"; }
harness_id_strategy()   { echo "assign"; }
harness_quit_keys()     { echo "/exit"; }

# Provider/auth vars Claude resolves from the process env (issue #18). Pinned
# empty when unset here (kills stale tmux-global values that leak in because a
# new tmux session inherits the SERVER's global env, not this process's); left
# to inherit when set here (so credentials travel with the selector).
# CLAUDE_CODE_SSE_PORT is always pinned empty (IDE-only, never an auth channel).
_CLAUDE_PROVIDER_ENV_VARS=(
  CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST
  CLAUDE_CODE_USE_BEDROCK
  CLAUDE_CODE_USE_VERTEX
  CLAUDE_CODE_USE_FOUNDRY
  CLAUDE_CODE_USE_ANTHROPIC_AWS
  CLAUDE_CODE_USE_MANTLE
)

# Populate the caller-declared WORKER_ENV_ARGS array with -e VAR=… pairs.
harness_env_args() {
  WORKER_ENV_ARGS=(-e "CLAUDE_CODE_SSE_PORT=")
  local var val
  for var in "${_CLAUDE_PROVIDER_ENV_VARS[@]}"; do
    val=$(printenv "$var" 2>/dev/null) || val=""
    if [ -z "$val" ]; then
      WORKER_ENV_ARGS+=(-e "${var}=")
    fi
  done
}

# Print the harness command + flags (one token per line) for `mode`:
#   launch -> --session-id <sid>;  resume -> --resume <sid>
# The spine wraps this with tmux + env args + any user extra-args.
harness_launch_argv() {
  local mode="$1" sid="$2" plugin_dir="$3"
  local bin idflag
  bin=$(harness_bin)
  idflag="--session-id"
  [ "$mode" = "resume" ] && idflag="--resume"
  printf '%s\n' \
    "$bin" "$idflag" "$sid" --plugin-dir "$plugin_dir" \
    --settings '{"skipDangerousModePermissionPrompt":true}' \
    --dangerously-skip-permissions \
    --disallowed-tools AskUserQuestion
}
