#!/bin/bash
# Pi (Earendil) harness driver for csd. Sourced, not executed. derive-id, but the
# control plane is a POLLER (Pi has no hooks): `csd poll` tails the session JSONL,
# self-registers the meta, and synthesizes the same events.jsonl the spine
# consumes. Validated end-to-end against pi 0.75.3.

harness_id()            { echo "pi"; }
harness_bin()           { echo "${CSD_PI_BIN:-pi}"; }
harness_control_plane() { echo "poll"; }
harness_id_strategy()   { echo "derive"; }
harness_quit_keys()     { echo "/quit"; }

# harness_poll <session_dir> <worker_dir> <tmux_name>
# Tail the newest session JSONL in <session_dir>; self-register <sid>.meta from
# line 1; map records -> normalized events; exit (emitting session_end) when the
# worker's tmux session is gone. Runs in a second tmux window of the worker.
harness_poll() {
  local sd="$1" wd="$2" tn="$3" f="" i
  # Discover the NEWEST session file (ls -t, not unsorted find), retrying.
  for i in $(seq 1 240); do
    f=$(ls -t "$sd"/*.jsonl 2>/dev/null | head -1) || f=""
    [ -n "$f" ] && [ -f "$f" ] && break
    f=""
    tmux has-session -t "$tn" 2>/dev/null || return 0
    sleep 0.5
  done
  [ -z "$f" ] && return 0
  # Read the session id from line 1, retrying: find can see the file before pi
  # flushes line 1 (TOCTOU). A one-shot read would kill the sole event producer.
  local sid="" cwd=""
  for i in $(seq 1 240); do
    sid=$(head -1 "$f" 2>/dev/null | jq -r '.id // empty' 2>/dev/null) || sid=""
    [ -n "$sid" ] && break
    tmux has-session -t "$tn" 2>/dev/null || return 0
    sleep 0.5
  done
  [ -z "$sid" ] && return 0
  cwd=$(head -1 "$f" 2>/dev/null | jq -r '.cwd // empty' 2>/dev/null) || cwd=""
  if [ ! -f "$wd/$sid.meta" ]; then
    jq -n --arg tn "$tn" --arg sid "$sid" --arg cwd "$cwd" --arg tp "$f" \
      '{tmux_name:$tn, session_id:$sid, cwd:$cwd, transcript_path:$tp, harness:"pi"}' \
      > "$wd/$sid.meta"
  fi
  local ev="$wd/$sid.events.jsonl"
  _pi_emit(){ jq -cn --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" --arg e "$1" '{ts:$ts, event:$e}' >> "$ev"; }
  _pi_emit session_start
  local prev=1 n line typ role stop read_cnt
  while true; do
    # File vanished (rotation/cleanup) -> end the session cleanly, don't crash.
    if [ ! -f "$f" ]; then _pi_emit session_end; break; fi
    n=$(wc -l < "$f" 2>/dev/null | tr -d ' ') || n=""
    if [ -n "$n" ] && [ "$n" -gt "$prev" ]; then
      read_cnt=0
      while IFS= read -r line; do
        read_cnt=$((read_cnt + 1))   # count every line read (advance offset by what we consumed)
        [ -z "$line" ] && continue
        typ=$(printf '%s' "$line" | jq -r '.type // empty' 2>/dev/null) || typ=""
        role=$(printf '%s' "$line" | jq -r '.message.role // empty' 2>/dev/null) || role=""
        stop=$(printf '%s' "$line" | jq -r '.message.stopReason // empty' 2>/dev/null) || stop=""
        case "$typ:$role:$stop" in
          message:user:*)            _pi_emit user_prompt_submit ;;
          message:assistant:toolUse) _pi_emit pre_tool_use ;;
          message:assistant:?*)      _pi_emit stop ;;   # any non-toolUse terminal stopReason
          message:toolResult:*)      _pi_emit post_tool_use ;;
        esac
      done < <(tail -n +"$((prev + 1))" "$f" 2>/dev/null)
      prev=$((prev + read_cnt))      # advance by lines actually consumed, NOT the stale wc -l
    fi
    tmux has-session -t "$tn" 2>/dev/null || { _pi_emit session_end; break; }
    sleep 0.3
  done
}

# Stage Pi auth into a per-worker config dir + create the session dir. The spine
# sets _CSD_CURRENT_WORKER_HOME to <worker_dir>/homes/<tmux_name>.
harness_prepare() {
  local tmux_name="$1" cwd="$2" home="$3"
  mkdir -p "$home/sessions"
  if [ -d "$HOME/.pi/agent" ]; then
    cp "$HOME/.pi/agent/auth.json" "$home/" 2>/dev/null || true
    cp "$HOME/.pi/agent/settings.json" "$home/" 2>/dev/null || true
  fi
}

# harness_launch_argv <mode> <sid> <cwd> <plugin_dir> <worker_home>
# Interactive pi; sessions isolated to the per-worker dir; reproducibility flags.
harness_launch_argv() {
  local home="$5"
  local model="${CSD_PI_MODEL:-openai-codex/gpt-5.5}"
  printf '%s\n' \
    "$(harness_bin)" \
    --session-dir "$home/sessions" \
    --model "$model" \
    --no-extensions --no-skills
}

# PI_CODING_AGENT_DIR (staged auth) + PI_CODING_AGENT_SESSION_DIR (worker sessions).
harness_env_args() {
  local home="${_CSD_CURRENT_WORKER_HOME:-}"
  WORKER_ENV_ARGS=(-e "PI_CODING_AGENT_DIR=${home}" -e "PI_CODING_AGENT_SESSION_DIR=${home}/sessions")
}

# Start the poller in a second tmux window of the worker's session (dies with it).
harness_post_launch() {
  local tmux_name="$1"
  local sd="${_CSD_CURRENT_WORKER_HOME:-}/sessions"
  # -d: do NOT switch the active window — cmd_send targets the session's active
  # window, which must stay pi's (window 0), not the poller's (B1 from review).
  tmux new-window -d -t "$tmux_name" -n csd-poll \
    "exec '$CSD_PATH' poll pi '$sd' '$_CSD_WORKER_DIR' '$tmux_name'"
}

# derive readiness: wait for the pi status bar, else settle (first send re-confirms).
harness_await_ready() {
  local tmux_name="$1" deadline=$((SECONDS + 20)) pane
  while [ "$SECONDS" -lt "$deadline" ]; do
    pane=$(tmux capture-pane -t "$tmux_name" -p 2>/dev/null || true)
    echo "$pane" | grep -q 'auto)' && return 0
    sleep 0.5
  done
  return 0
}

# transcript path recorded by the poller; read from meta.
harness_transcript_path() {
  local sid="$1"
  jq -r '.transcript_path // empty' "$_CSD_WORKER_DIR/${sid}.meta" 2>/dev/null
}

# Render the last turn of a pi session file as markdown.
harness_parse_turn() {
  local sf="$1"
  [ -f "$sf" ] || { echo "No session at $sf" >&2; return 1; }
  local start=""
  start=$(grep -n '"role":"user"' "$sf" | tail -1 | cut -d: -f1) || start=""
  [ -z "$start" ] && start=1
  tail -n +"$start" "$sf" | jq -r '
    select(.type=="message") | .message as $m |
    if   $m.role=="user"      then "**[user]** " + ([$m.content[]?|select(.type=="text").text]|join(""))+"\n"
    elif $m.role=="assistant" then
      ([$m.content[]? |
        if .type=="text" then .text
        elif .type=="toolCall" then "\n**Tool: "+.name+"**\n```\n"+(.arguments|tostring)+"\n```"
        else empty end] | join(""))+"\n"
    elif $m.role=="toolResult" then "**Result:**\n```\n" + ([$m.content[]?|select(.type=="text").text]|join(""))+"\n```\n"
    else empty end' 2>/dev/null
}
harness_count_text() {
  local sf="$1" c
  [ -f "$sf" ] || { echo 0; return; }
  c=$(grep -c '"role":"assistant"' "$sf" 2>/dev/null) || c=0
  echo "$c"
}
harness_last_text() {
  local sf="$1"
  [ -f "$sf" ] || return 0
  grep '"role":"assistant"' "$sf" \
    | jq -rs 'map(select(.message.role=="assistant")) | last | [.message.content[]?|select(.type=="text").text]|join("")' 2>/dev/null || true
}
