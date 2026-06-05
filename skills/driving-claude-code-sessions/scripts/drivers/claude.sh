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

# Echo the transcript path for <sid> in <cwd> (cwd resolved to absolute first).
harness_transcript_path() {
  local sid="$1" cwd="$2"
  if [ -d "$cwd" ]; then cwd=$(cd "$cwd" && pwd -P); fi
  local encoded="${cwd//\//-}"
  echo "$HOME/.claude/projects/${encoded}/${sid}.jsonl"
}

# Render the last turn of <transcript> as markdown. With --full, tool results
# are shown complete; otherwise truncated to 5 lines.
harness_parse_turn() {
  local log_file="$1" full=false
  [ "${2:-}" = "--full" ] && full=true
  local last_prompt_line
  last_prompt_line=$(grep -n '"type":"user"' "$log_file" \
    | grep -v '"tool_result"' | grep -v '<local-command' | grep -v '<command-name>' \
    | tail -1 | cut -d: -f1)
  if [ -z "$last_prompt_line" ]; then
    echo "No user prompt found in session log" >&2
    return 1
  fi
  tail -n +"$last_prompt_line" "$log_file" \
    | jq -r --argjson full "$full" '
      select(.type == "assistant" or .type == "user") |
      if .type == "user" then
        if (.message.content | type) == "string" then
          if (.message.content | test("^<(local-command|command-name)")) then empty
          else "---\n\n**Prompt:** " + .message.content + "\n" end
        else
          .message.content[] | select(.type == "tool_result") |
          if .is_error then
            "**Tool Error:**\n```\n" + (.content // "(no output)") + "\n```\n"
          else
            if $full then
              "**Result:**\n```\n" + (.content // "(no output)") + "\n```\n"
            else
              "**Result:**\n```\n" + ((.content // "(no output)") | split("\n") | if length > 5 then (.[0:5] | join("\n")) + "\n... (" + (length | tostring) + " lines total)" else join("\n") end) + "\n```\n"
            end
          end
        end
      elif .type == "assistant" then
        .message.content[] |
        if .type == "thinking" then "> **Thinking:** " + (.thinking | split("\n") | join("\n> ")) + "\n"
        elif .type == "text" then .text + "\n"
        elif .type == "tool_use" then "**Tool: " + .name + "**\n```json\n" + (.input | tostring) + "\n```\n"
        else empty
        end
      else empty
      end
    ' 2>/dev/null
}

# Echo the count of assistant messages that contain a text block.
harness_count_text() {
  local log_file="$1"
  [ -f "$log_file" ] || { echo 0; return; }
  local r
  r=$(grep '"type":"assistant"' "$log_file" \
      | jq -s '[.[] | select(.message.content | (type == "array") and any(.type == "text"))] | length' 2>/dev/null) || r=0
  echo "$r"
}

# Echo the text of the last assistant message that has a text block.
harness_last_text() {
  local log_file="$1"
  grep '"type":"assistant"' "$log_file" \
    | jq -rs 'map(select(.message.content | (type == "array") and any(.type == "text"))) | last | [.message.content[] | select(.type == "text") | .text] | join("\n")' 2>/dev/null
}
