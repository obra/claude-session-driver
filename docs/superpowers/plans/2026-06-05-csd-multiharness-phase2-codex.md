# CSD Multi-Harness — Phase 2: Codex Driver Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Drive **Codex** workers through `csd` — same controller-facing contract as Claude — by adding the `derive`-id identity flow + a self-registering Codex hook, reusing the existing `events.jsonl` control plane.

**Architecture:** Codex mints its own session id (no `--session-id`). A per-worker `CODEX_HOME` holds a generated `config.toml` whose lifecycle hooks run **`emit-event-codex`**, which *self-registers* `<sid>.meta` and appends the normalized `<sid>.events.jsonl` from the SessionStart payload. Once registered, every downstream command (`wait-for-turn`/`status`/`read-events`/`converse`) works **unchanged** from Phase 1. The one new spine behavior is tolerating the **pre-registration window** (launch → first prompt). This entire flow is **validated end-to-end against real codex 0.134** (spec Appendix B).

**Tech Stack:** Bash 3.2 (no `mapfile`/assoc arrays), `jq`, `tmux`, `codex` CLI. Codex mocked in tests via `CSD_CODEX_BIN` → a fake that simulates the self-registering hooks + a rollout.

**Spec:** `docs/superpowers/specs/2026-06-05-csd-multiharness-design.md` (esp. **Appendix B**).

**Depends on:** Phase 1 (driver slots, `/tmp/csd-workers`, `--harness`). **Out of scope:** Pi (Phase 3) — but the derive-id spine built here is reused by Pi.

---

## File Structure

- **Create** `scripts/drivers/codex.sh` — Codex driver slots.
- **Create** `hooks/emit-event-codex` — self-registering hook (the validated prototype script).
- **Modify** `scripts/csd` — `cmd_launch` branches on `harness_id_strategy`; new slot calls (`harness_prepare`, `harness_post_launch`, `harness_await_ready`); pre-registration tolerance in `cmd_send`/`cmd_converse`.
- **Modify** `scripts/drivers/claude.sh` — widen `harness_launch_argv` signature; add no-op `harness_prepare`/`harness_post_launch`/`harness_await_ready`.
- **Modify** `scripts/_lib.sh` — add `_worker_tmux_name` helper (resolves the tmux session name without requiring a registered sid).
- **Create** `tests/fixtures/fake-codex` — simulates codex: on launch, fires the configured hooks with synthetic payloads + writes a minimal rollout.
- **Create** `tests/test-csd-codex.sh` — driver unit tests + a fake-codex integration test (launch → converse → read-turn).
- **Create** `tests/test-emit-event-codex.sh` — hook self-registration unit test.

### Slot contract additions (extends Phase 1)

```
harness_launch_argv <mode> <sid> <cwd> <plugin_dir> <worker_home>   # WIDENED (was <mode> <sid> <plugin_dir>)
harness_prepare     <tmux_name> <cwd> <worker_home>                 # set up per-worker config; "" = nothing
harness_post_launch <tmux_name>                                     # dismiss startup gates; "" = nothing
harness_await_ready <tmux_name> <session_id_or_empty>               # assign: session_start; derive: composer/settle
```

`harness_id_strategy` (already a slot) drives the branch: `assign` → pre-write meta + `--session-id` + await `session_start`; `derive` → no pre-meta, self-registration, await composer.

---

## Task 1: Widen `harness_launch_argv`; add no-op lifecycle slots to Claude

Keep Phase 1 green while making room for Codex. The widened signature adds `cwd` and `worker_home` (Claude ignores them).

**Files:** `scripts/drivers/claude.sh`, `scripts/csd`, `tests/test-csd-drivers.sh`

- [ ] **Step 1: Update the Claude slot test** — in `tests/test-csd-drivers.sh`, change the two `harness_launch_argv launch SID123 /plug` / `... resume SID123 /plug` calls to the new arity: `harness_launch_argv launch SID123 /cwd /plug /home` and `harness_launch_argv resume SID123 /cwd /plug /home`. (Assertions unchanged — Claude ignores the new args.)

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test-csd-drivers.sh`
Expected: FAIL (extra args shift nothing for Claude, but confirm the call still works; if green already, proceed — the arity is positional and Claude reads only $1,$2,$4).

- [ ] **Step 3: Widen `harness_launch_argv` in `drivers/claude.sh`**

```bash
# harness_launch_argv <mode> <sid> <cwd> <plugin_dir> <worker_home>
# Claude uses mode, sid, plugin_dir; ignores cwd + worker_home.
harness_launch_argv() {
  local mode="$1" sid="$2" plugin_dir="$4"
  local bin idflag
  bin=$(harness_bin)
  idflag="--session-id"; [ "$mode" = "resume" ] && idflag="--resume"
  printf '%s\n' \
    "$bin" "$idflag" "$sid" --plugin-dir "$plugin_dir" \
    --settings '{"skipDangerousModePermissionPrompt":true}' \
    --dangerously-skip-permissions \
    --disallowed-tools AskUserQuestion
}
```

- [ ] **Step 4: Add no-op lifecycle slots to `drivers/claude.sh`** (append):

```bash
# Claude needs no per-worker prep, no post-launch gate dismissal.
harness_prepare()     { :; }
harness_post_launch() { :; }
# Claude readiness == session_start (the spine's existing _await_session_start
# is invoked directly for assign harnesses; this slot is the derive path's hook).
harness_await_ready() { :; }
```

- [ ] **Step 5: Update the two `csd` call sites** to the widened arity

In `cmd_launch`: `harness_launch_argv launch "$session_id" "$working_dir" "$plugin_dir" ""`.
In `cmd_adopt`: `harness_launch_argv resume "$session_id" "$working_dir" "$plugin_dir" ""`.
(Both currently pass `launch "$session_id" "$plugin_dir"` / `resume ...`. Add `"$working_dir"` and `""`.)

- [ ] **Step 6: Run the full suite**

Run: `for t in tests/test-*.sh; do bash "$t" >/dev/null 2>&1 && echo "ok $t" || echo "FAIL $t"; done`
Expected: all green (Claude behavior unchanged).

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "refactor(csd): widen harness_launch_argv + add no-op lifecycle slots (PRI-2096)"
```

---

## Task 2: `emit-event-codex` — the self-registering hook

The validated prototype hook. Reads the Codex hook JSON on stdin; self-registers `<sid>.meta`; appends normalized events.

**Files:** `hooks/emit-event-codex`, `tests/test-emit-event-codex.sh`

- [ ] **Step 1: Write the failing test** — `tests/test-emit-event-codex.sh`

```bash
#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/emit-event-codex"
PASS=0; FAIL=0
pass(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
fail(){ echo "  FAIL: $1 - $2"; FAIL=$((FAIL+1)); }
WD=$(mktemp -d)
SID="019e0000-0000-7000-8000-000000000001"
# SessionStart self-registers the meta from the payload.
printf '%s' "{\"session_id\":\"$SID\",\"transcript_path\":\"/r/$SID.jsonl\",\"cwd\":\"/w\",\"hook_event_name\":\"SessionStart\"}" \
  | "$HOOK" my-worker /w "$WD"
[ -f "$WD/$SID.meta" ] && pass "meta self-registered" || fail "meta" "missing"
[ "$(jq -r '.harness' "$WD/$SID.meta")" = "codex" ] && pass "harness=codex" || fail "harness" "wrong"
[ "$(jq -r '.tmux_name' "$WD/$SID.meta")" = "my-worker" ] && pass "tmux_name baked" || fail "tmux_name" "wrong"
[ "$(jq -r '.transcript_path' "$WD/$SID.meta")" = "/r/$SID.jsonl" ] && pass "transcript_path captured" || fail "tp" "wrong"
[ "$(tail -1 "$WD/$SID.events.jsonl" | jq -r '.event')" = "session_start" ] && pass "session_start event" || fail "event" "wrong"
# PreToolUse carries the tool name.
printf '%s' "{\"session_id\":\"$SID\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\"}" | "$HOOK" my-worker /w "$WD"
[ "$(tail -1 "$WD/$SID.events.jsonl" | jq -r '.tool')" = "Bash" ] && pass "pre_tool_use tool" || fail "tool" "wrong"
# Stop maps to turn-end.
printf '%s' "{\"session_id\":\"$SID\",\"hook_event_name\":\"Stop\"}" | "$HOOK" my-worker /w "$WD"
[ "$(tail -1 "$WD/$SID.events.jsonl" | jq -r '.event')" = "stop" ] && pass "stop event" || fail "stop" "wrong"
# Missing session_id → no-op, exit 0.
printf '%s' '{"hook_event_name":"Stop"}' | "$HOOK" my-worker /w "$WD" && pass "no-sid no-ops" || fail "no-sid" "nonzero exit"
rm -rf "$WD"
echo "emit-event-codex: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: Run to verify it fails** — Run: `bash tests/test-emit-event-codex.sh` → Expected: FAIL (hook missing).

- [ ] **Step 3: Write `hooks/emit-event-codex`** (the validated prototype, hardened)

```bash
#!/bin/bash
set -euo pipefail
# Codex lifecycle hook for csd. Self-registers the worker meta and appends
# normalized events to <sid>.events.jsonl. Args: <tmux_name> <cwd> <worker_dir>.
# Codex bakes these into the hook command in the per-worker CODEX_HOME config.toml.
TN="${1:-}"; CWD="${2:-}"; WD="${3:-}"
[ -z "$WD" ] && exit 0
INPUT=""
IFS= read -t 5 -d '' INPUT || true
[ -z "$INPUT" ] && exit 0
printf '%s' "$INPUT" | jq -e . >/dev/null 2>&1 || exit 0
SID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty')
[ -z "$SID" ] && exit 0
EV=$(printf '%s' "$INPUT" | jq -r '.hook_event_name // empty')
TP=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty')
mkdir -p "$WD"
if [ ! -f "$WD/$SID.meta" ]; then
  jq -n --arg tn "$TN" --arg sid "$SID" --arg cwd "$CWD" --arg tp "$TP" \
    '{tmux_name:$tn, session_id:$sid, cwd:$cwd, transcript_path:$tp, harness:"codex"}' \
    > "$WD/$SID.meta"
fi
case "$EV" in
  SessionStart)     e=session_start ;;
  UserPromptSubmit) e=user_prompt_submit ;;
  PreToolUse)       e=pre_tool_use ;;
  Stop)             e=stop ;;
  SessionEnd)       e=session_end ;;
  *)                e=$(echo "$EV" | sed 's/\([A-Z]\)/_\L\1/g; s/^_//') ;;
esac
ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
if [ "$e" = pre_tool_use ]; then
  tool=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""')
  ti=$(printf '%s' "$INPUT" | jq -c '.tool_input // {}')
  jq -cn --arg ts "$ts" --arg event "$e" --arg tool "$tool" --argjson ti "$ti" \
    '{ts:$ts, event:$event, tool:$tool, tool_input:$ti}' >> "$WD/$SID.events.jsonl"
else
  jq -cn --arg ts "$ts" --arg event "$e" '{ts:$ts, event:$event}' >> "$WD/$SID.events.jsonl"
fi
exit 0
```

- [ ] **Step 4: Run the test** — Run: `bash tests/test-emit-event-codex.sh` → Expected: PASS (8 assertions).

- [ ] **Step 5: Commit**

```bash
git add hooks/emit-event-codex tests/test-emit-event-codex.sh
git commit -m "feat(csd): self-registering emit-event-codex hook (PRI-2096)"
```

---

## Task 3: `drivers/codex.sh` — manifest + prepare + launch + post-launch slots

**Files:** `scripts/drivers/codex.sh`, `tests/test-csd-codex.sh`

- [ ] **Step 1: Write failing driver unit tests** — `tests/test-csd-codex.sh` (driver section)

```bash
#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCR="$SCRIPT_DIR/../skills/driving-claude-code-sessions/scripts"
PASS=0; FAIL=0
pass(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
fail(){ echo "  FAIL: $1 - $2"; FAIL=$((FAIL+1)); }
probe(){ ( source "$SCR/_lib.sh"; _load_driver codex; "$@" ); }
[ "$(probe harness_id)" = "codex" ] && pass "id=codex" || fail "id" "wrong"
[ "$(probe harness_control_plane)" = "hooks" ] && pass "control_plane=hooks" || fail "cp" "wrong"
[ "$(probe harness_id_strategy)" = "derive" ] && pass "id_strategy=derive" || fail "ids" "wrong"
[ "$(probe harness_quit_keys)" = "/quit" ] && pass "quit=/quit" || fail "quit" "wrong"
[ "$(probe harness_bin)" = "codex" ] && pass "bin=codex" || fail "bin" "wrong"
# prepare writes a CODEX_HOME config.toml with hooks + project trust
HOME_DIR=$(mktemp -d); CWD=$(mktemp -d)
( source "$SCR/_lib.sh"; _load_driver codex; CSD_PLUGIN_DIR=/plug harness_prepare wkr "$CWD" "$HOME_DIR" )
[ -f "$HOME_DIR/config.toml" ] && pass "config.toml written" || fail "config" "missing"
grep -q 'emit-event-codex wkr' "$HOME_DIR/config.toml" && pass "hook bakes tmux_name" || fail "hook arg" "missing"
grep -q "\\[\\[hooks.SessionStart\\]\\]" "$HOME_DIR/config.toml" && pass "SessionStart hook" || fail "sshook" "missing"
grep -q "trust_level" "$HOME_DIR/config.toml" && pass "project trust" || fail "trust" "missing"
# launch argv: no --session-id; has -C <cwd> + bypass flags
av=$( ( source "$SCR/_lib.sh"; _load_driver codex; harness_launch_argv launch "" "$CWD" /plug "$HOME_DIR" ) )
echo "$av" | grep -qx -- "--dangerously-bypass-approvals-and-sandbox" && pass "yolo flag" || fail "yolo" "missing"
echo "$av" | grep -qx -- "--session-id" && fail "no sid" "should be absent" || pass "no --session-id"
echo "$av" | grep -qx -- "-C" && pass "-C cwd" || fail "-C" "missing"
rm -rf "$HOME_DIR" "$CWD"
echo "codex-driver: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: Run to verify it fails** — Run: `bash tests/test-csd-codex.sh` → Expected: FAIL (no codex driver).

- [ ] **Step 3: Write `drivers/codex.sh`**

```bash
#!/bin/bash
# Codex (OpenAI) harness driver for csd. Sourced, not executed. derive-id +
# hook control plane. See spec Appendix B.

harness_id()            { echo "codex"; }
harness_bin()           { echo "${CSD_CODEX_BIN:-codex}"; }
harness_control_plane() { echo "hooks"; }
harness_id_strategy()   { echo "derive"; }
harness_quit_keys()     { echo "/quit"; }

# Per-worker config: CODEX_HOME holds a config.toml registering the
# self-registering hook on each lifecycle event, plus project trust. Auth is
# staged so the worker authenticates as the operator (subscription).
# Reads CSD_PLUGIN_DIR (set by the spine) to locate emit-event-codex.
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
# Codex ignores sid (derive) + plugin_dir (hooks via CODEX_HOME) + worker_home
# (passed as env by harness_env_args). Interactive; -C sets the workdir.
harness_launch_argv() {
  local cwd="$3"
  printf '%s\n' \
    "$(harness_bin)" \
    --dangerously-bypass-approvals-and-sandbox \
    --dangerously-bypass-hook-trust \
    -C "$cwd"
}

# CODEX_HOME points codex at the per-worker config/auth/sessions dir.
# The spine sets _CSD_CURRENT_WORKER_HOME before calling this.
harness_env_args() {
  WORKER_ENV_ARGS=(-e "CODEX_HOME=${_CSD_CURRENT_WORKER_HOME}")
}

# Dismiss the "Hooks need review" trust gate (bypass flag does NOT auto-skip it).
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

# derive readiness: no session_start at boot (it fires at first prompt). Wait
# for the composer to appear, else a short settle.
harness_await_ready() {
  local tmux_name="$1" deadline=$((SECONDS + 20)) pane
  while [ "$SECONDS" -lt "$deadline" ]; do
    pane=$(tmux capture-pane -t "$tmux_name" -p 2>/dev/null || true)
    echo "$pane" | grep -q '›' && return 0   # codex composer prompt glyph
    sleep 0.5
  done
  return 0   # best-effort; the first send re-confirms via self-registration
}

# transcript path is recorded by the self-registering hook; read it from meta.
harness_transcript_path() {
  local sid="$1"
  jq -r '.transcript_path // empty' "$_CSD_WORKER_DIR/${sid}.meta" 2>/dev/null
}
```

(`harness_parse_turn`/`harness_count_text`/`harness_last_text` for codex are added in Task 5.)

- [ ] **Step 4: Run the driver test** — Run: `bash tests/test-csd-codex.sh` → Expected: the driver-section assertions PASS (the integration test is added in Task 6 and will fail until then; split the file or guard it — see Task 6).

- [ ] **Step 5: Commit**

```bash
git add skills/driving-claude-code-sessions/scripts/drivers/codex.sh tests/test-csd-codex.sh
git commit -m "feat(csd): codex driver manifest + prepare/launch/post-launch slots (PRI-2096)"
```

---

## Task 4: Spine — `derive` launch branch in `cmd_launch`

Branch `cmd_launch` on `harness_id_strategy`. `assign` keeps Phase 1 exactly; `derive` runs prepare → launch → post_launch → await_ready, with **no** pre-written meta and **no** `_await_session_start`.

**Files:** `scripts/csd`

- [ ] **Step 1: Export plugin dir + set per-worker home for drivers**

Near the top of `cmd_launch` (after `plugin_dir` is resolved), add:
```bash
  export CSD_PLUGIN_DIR="$plugin_dir"
  local worker_home="$_CSD_WORKER_DIR/homes/$tmux_name"
  _CSD_CURRENT_WORKER_HOME="$worker_home"
```

- [ ] **Step 2: Gate the assign-only pre-meta + id generation**

Wrap the `session_id=$(uuidgen…)` + meta `jq -n … > <sid>.meta` block in:
```bash
  local session_id=""
  if [ "$(harness_id_strategy)" = "assign" ]; then
    session_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
    # ... existing meta pre-write keyed by $session_id ...
  fi
```

- [ ] **Step 3: Call `harness_prepare` before launch, branch the readiness**

Replace the launch sequence so it reads:
```bash
  harness_prepare "$tmux_name" "$working_dir" "$worker_home"
  local launch_argv=()
  while IFS= read -r _tok; do launch_argv+=("$_tok"); done \
    < <(harness_launch_argv launch "$session_id" "$working_dir" "$plugin_dir" "$worker_home")
  local WORKER_ENV_ARGS=()
  harness_env_args
  tmux new-session -d -s "$tmux_name" -c "$working_dir" \
    "${WORKER_ENV_ARGS[@]}" "${launch_argv[@]}" \
    "${extra_args[@]+"${extra_args[@]}"}"
  harness_post_launch "$tmux_name"
  if [ "$(harness_id_strategy)" = "assign" ]; then
    _await_session_start "$tmux_name" "$session_id" || return 1
  else
    harness_await_ready "$tmux_name" ""
  fi
```

- [ ] **Step 4: Fix the events-path panel line for derive**

The "Worker launched" stderr panel references `$_CSD_WORKER_DIR/${session_id}.events.jsonl`. For derive, `session_id` is empty at this point. Make the events line conditional:
```bash
  if [ -n "$session_id" ]; then
    echo "  events:     $_CSD_WORKER_DIR/${session_id}.events.jsonl"
  else
    echo "  events:     (registered on first prompt; csd list will show it)"
  fi
```

- [ ] **Step 5: Smoke with the fake (deferred)** — the real check is Task 6's integration test. For now:

Run: `bash -n skills/driving-claude-code-sessions/scripts/csd && echo ok`
Run: `for t in tests/test-*.sh; do bash "$t" >/dev/null 2>&1 || echo "FAIL $t"; done`
Expected: parses; all Phase-1 (assign/Claude) tests still green.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat(csd): derive-id launch branch in cmd_launch (PRI-2096)"
```

---

## Task 5: Codex turn parser + pre-registration tolerance in send/converse

**Files:** `scripts/drivers/codex.sh`, `scripts/csd`, `scripts/_lib.sh`

- [ ] **Step 1: Add `_worker_tmux_name` to `_lib.sh`** (resolve the tmux session without a registered sid)

```bash
# Print the tmux session name for <worker>. Works before self-registration:
# falls back to <worker> itself when it names a live tmux session (the shim sets
# --worker to the tmux_name).
_worker_tmux_name() {
  local worker="$1" sid meta tn
  sid=$(resolve_session "$worker" 2>/dev/null) || sid=""
  if [ -n "$sid" ] && [ -f "$_CSD_WORKER_DIR/${sid}.meta" ]; then
    tn=$(jq -r '.tmux_name' "$_CSD_WORKER_DIR/${sid}.meta" 2>/dev/null)
    [ -n "$tn" ] && [ "$tn" != "null" ] && { echo "$tn"; return 0; }
  fi
  if tmux has-session -t "$worker" 2>/dev/null; then echo "$worker"; return 0; fi
  echo "$worker"
}
```

- [ ] **Step 2: `cmd_send` — use `_worker_tmux_name`; relax submit-confirm for derive**

In `cmd_send`, replace `tmux_name=$(jq -r '.tmux_name' "$_CSD_WORKER_DIR/${sid}.meta")` (which needs a sid) with `tmux_name=$(_worker_tmux_name "$WORKER")`, and the `before_line`/`_prompt_submitted_since` logic: for derive workers with no sid yet, poll for self-registration first, then confirm via the registered events file. Concretely, after sending the paste+Enter, replace the confirm loop with:
```bash
  # Discover the (possibly just-registered) session + events file.
  local sid events_file
  sid=$(resolve_session "$WORKER" 2>/dev/null) || sid=""
  if [ -z "$sid" ]; then
    # derive: wait up to submit_timeout for the hook to self-register.
    local d=$((SECONDS + submit_timeout))
    while [ "$SECONDS" -lt "$d" ] && [ -z "$sid" ]; do sleep 0.25; sid=$(resolve_session "$WORKER" 2>/dev/null) || sid=""; done
  fi
  [ -n "$sid" ] && events_file="$_CSD_WORKER_DIR/${sid}.events.jsonl"
```
then key the existing `_prompt_submitted_since`/retry on `$events_file` (skip the retry gracefully if `$sid` is still empty — self-registration is the confirmation). Preserve the assign path exactly (sid is known up front).

- [ ] **Step 3: `cmd_converse` — resolve sid AFTER the first send for derive**

`cmd_converse` currently resolves `sid`/`cwd`/`log_file` before sending. For derive, move the sid/log_file resolution to AFTER `cmd_send` returns (when self-registration has happened). Structure:
```bash
  if [ "$(harness_id_strategy)" = "assign" ]; then
    sid=$(resolve_session "$WORKER"); cwd=$(jq -r .cwd "$_CSD_WORKER_DIR/$sid.meta"); log_file=$(harness_transcript_path "$sid" "$cwd"); before_count=$(harness_count_text "$log_file")
  fi
  cmd_send "$prompt"
  if [ "$(harness_id_strategy)" = "derive" ]; then
    sid=$(resolve_session "$WORKER"); log_file=$(harness_transcript_path "$sid")  # codex reads tp from meta
    before_count=0
  fi
  # ... existing wait_for_turn on <sid>.events.jsonl, then read response ...
```
(`harness_transcript_path` for codex takes just `<sid>` — it reads `transcript_path` from meta. Claude's takes `<sid> <cwd>`. Both are called with the args each needs; the spine passes `"$sid" "$cwd"` and codex ignores `$2`.)

- [ ] **Step 4: Add the codex turn parser to `drivers/codex.sh`**

```bash
# Render the last turn of a codex rollout as markdown.
harness_parse_turn() {
  local rollout="$1" full=false
  [ "${2:-}" = "--full" ] && full=true
  [ -f "$rollout" ] || { echo "No rollout at $rollout" >&2; return 1; }
  # Last user message line onward.
  local start
  start=$(grep -n '"type":"response_item"' "$rollout" | grep '"role":"user"' | tail -1 | cut -d: -f1)
  [ -z "$start" ] && start=1
  tail -n +"$start" "$rollout" | jq -r '
    select(.type=="response_item") | .payload as $p |
    if   $p.type=="message" then "**["+$p.role+"]** " + ([$p.content[]?.text // $p.content[]?.output_text // ""] | join(""))+"\n"
    elif $p.type=="reasoning" then "> **Thinking:** " + (($p.summary // []) | map(.text // .) | join(" "))+"\n"
    elif $p.type=="function_call" then "**Tool: "+$p.name+"**\n```\n"+$p.arguments+"\n```\n"
    elif $p.type=="function_call_output" then "**Result:**\n```\n"+($p.output|tostring)+"\n```\n"
    else empty end' 2>/dev/null
}
harness_count_text() {
  local rollout="$1"; [ -f "$rollout" ] || { echo 0; return; }
  grep -c '"type":"event_msg".*"agent_message"' "$rollout" 2>/dev/null || echo 0
}
harness_last_text() {
  local rollout="$1"; [ -f "$rollout" ] || return 0
  grep '"type":"event_msg"' "$rollout" | jq -rs 'map(select(.payload.type=="agent_message")) | last | .payload.message // ""' 2>/dev/null
}
```

- [ ] **Step 5: Verify Phase-1 suite still green** (assign path untouched)

Run: `for t in tests/test-*.sh; do bash "$t" >/dev/null 2>&1 || echo "FAIL $t"; done`
Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat(csd): codex turn parser + pre-registration tolerance (PRI-2096)"
```

---

## Task 6: Fake-codex integration test (launch → converse → read-turn)

A fake `codex` lets us test the whole derive flow without API calls. The fake reads its `CODEX_HOME/config.toml`, fires the SessionStart/UserPromptSubmit/PreToolUse/Stop hooks with synthetic payloads (so `emit-event-codex` self-registers), writes a minimal rollout at a path it reports via `transcript_path`, and `exec sleep`s to stay alive.

**Files:** `tests/fixtures/fake-codex`, `tests/test-csd-codex.sh`

- [ ] **Step 1: Write `tests/fixtures/fake-codex`**

```bash
#!/bin/bash
# Fake codex for tests. Parses -C <cwd>; reads CODEX_HOME/config.toml to find the
# emit-event-codex hook command; mints a uuid; fires hooks with synthetic
# payloads; writes a minimal rollout; stays alive.
cwd="."; while [ $# -gt 0 ]; do case "$1" in -C) cwd="$2"; shift 2;; *) shift;; esac; done
SID="019efake-0000-7000-8000-$(printf '%012d' $$)"
DAY=$(date -u +%Y/%m/%d)
ROLL="$CODEX_HOME/sessions/$DAY/rollout-$(date -u +%Y-%m-%dT%H-%M-%S)-$SID.jsonl"
mkdir -p "$(dirname "$ROLL")"
printf '{"type":"session_meta","payload":{"id":"%s","cwd":"%s"}}\n' "$SID" "$cwd" > "$ROLL"
# Extract the hook command (first emit-event-codex line) from config.toml.
HOOKCMD=$(grep -m1 'emit-event-codex' "$CODEX_HOME/config.toml" | sed 's/^command = "//; s/"$//')
fire(){ printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","hook_event_name":"%s"%s}' \
  "$SID" "$ROLL" "$cwd" "$1" "${2:-}" | $HOOKCMD; }
# A real codex fires hooks at first prompt; the fake fires them at boot for the
# test's first turn. (The test sends a prompt; we simulate the resulting turn.)
fire SessionStart
fire UserPromptSubmit ',"prompt":"hi"'
fire PreToolUse ',"tool_name":"Bash"'
printf '{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"FAKE_DONE"}]}}\n' >> "$ROLL"
printf '{"type":"event_msg","payload":{"type":"agent_message","message":"FAKE_DONE"}}\n' >> "$ROLL"
fire Stop
exec sleep 60
```

- [ ] **Step 2: Append the integration test to `tests/test-csd-codex.sh`**

```bash
# --- integration: fake-codex launch -> converse -> read-turn ---
FAKE="$SCRIPT_DIR/fixtures/fake-codex"; chmod +x "$FAKE"
IHOME=$(mktemp -d); mkdir -p "$IHOME/.codex"; touch "$IHOME/.codex/.claude-session-driver-consent"
ITN="test-codex-$$"; IWD=$(mktemp -d)
SHIM=$(CSD_CODEX_BIN="$FAKE" HOME="$IHOME" bash "$SCR/csd" launch --harness codex "$ITN" "$IWD" 2>/dev/null) || true
# The fake fires hooks at boot, so by now the worker self-registered.
sleep 1
OUT=$(CSD_CODEX_BIN="$FAKE" HOME="$IHOME" bash "$SCR/csd" --worker "$ITN" read-turn 2>/dev/null || true)
echo "$OUT" | grep -q "FAKE_DONE" && pass "codex read-turn renders the turn" || fail "read-turn" "got: $OUT"
ST=$(CSD_CODEX_BIN="$FAKE" HOME="$IHOME" bash "$SCR/csd" --worker "$ITN" status 2>/dev/null || true)
[ "$ST" = "idle" ] && pass "codex status idle after stop" || fail "status" "got $ST"
# cleanup
CSD_CODEX_BIN="$FAKE" HOME="$IHOME" bash "$SCR/csd" --worker "$ITN" stop >/dev/null 2>&1 || true
tmux kill-session -t "$ITN" 2>/dev/null || true
rm -rf "$IHOME" "$IWD"
```

(Note: the fake fires hooks at boot rather than on a real prompt, so the integration test exercises self-registration + events + read-turn + status without needing `send` to drive a real model. A separate **real-codex** smoke is Task 7.)

- [ ] **Step 3: Run the codex test** — Run: `bash tests/test-csd-codex.sh` → Expected: PASS (driver + integration).

- [ ] **Step 4: Full suite** — Run: `for t in tests/test-*.sh; do bash "$t" >/dev/null 2>&1 && echo "ok $t" || echo "FAIL $t"; done` → Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add tests/fixtures/fake-codex tests/test-csd-codex.sh
git commit -m "test(csd): fake-codex integration test for derive-id flow (PRI-2096)"
```

---

## Task 7: Real-codex smoke test (gated, manual)

A scripted real-codex run mirroring the validated prototype, runnable on demand (it costs a subscription turn). Not part of the default suite.

**Files:** `tests/smoke-codex-real.sh`

- [ ] **Step 1: Write `tests/smoke-codex-real.sh`** — launches a real codex worker via `csd launch --harness codex`, `converse`s a trivial tool-using prompt, asserts `read-turn` shows the result, then `stop`s. Guard with `[ -n "${CSD_RUN_REAL_CODEX:-}" ] || { echo "set CSD_RUN_REAL_CODEX=1 to run"; exit 0; }`.

- [ ] **Step 2: Run it once** — Run: `CSD_RUN_REAL_CODEX=1 bash tests/smoke-codex-real.sh` → Expected: a real Codex worker drives a turn end-to-end and `read-turn` shows the model's reply. Record the result in the PR/ticket.

- [ ] **Step 3: Commit**

```bash
git add tests/smoke-codex-real.sh
git commit -m "test(csd): gated real-codex end-to-end smoke (PRI-2096)"
```

---

## Final verification

- [ ] Full suite green: `for t in tests/test-*.sh; do echo "== $t =="; bash "$t" || break; done` — all `0 failed`.
- [ ] Real-codex smoke passed once (Task 7).
- [ ] `csd launch --harness codex <name> <cwd>` → `converse` → `read-turn` → `stop` works against real codex.
- [ ] Claude unchanged: every Phase-1 test still green (assign path untouched).

## Self-Review

**Spec coverage (Appendix B):** derive-id self-registration → Tasks 2,4; per-worker CODEX_HOME config + auth + trust → Task 3; trust-gate `2` dismissal → Task 3 (`harness_post_launch`); readiness-not-session_start → Tasks 3,4; pre-registration window tolerance → Task 5; codex rollout parser → Task 5; fake + real validation → Tasks 6,7.

**Placeholder scan:** none — hook + driver + fake are complete; the `cmd_launch`/`cmd_send`/`cmd_converse` edits show the exact branch code.

**Type/name consistency:** new slots `harness_prepare`/`harness_post_launch`/`harness_await_ready`, widened `harness_launch_argv` arity, `_worker_tmux_name`, `_CSD_CURRENT_WORKER_HOME`, `CSD_PLUGIN_DIR`, `CSD_CODEX_BIN`/`CSD_CODEX_MODEL` used consistently across tasks.

**Risks for the reviewer (Riker):**
- `cmd_converse`/`cmd_send` carry the most spine risk (the assign/derive branch + the post-send sid discovery). Verify the assign path is byte-for-byte behavior-preserving.
- `harness_env_args` for codex relies on `_CSD_CURRENT_WORKER_HOME` being set before launch — confirm scope/ordering in `cmd_launch`.
- The fake fires hooks at boot (not on a prompt); the real flow fires at first prompt. The integration test therefore can't exercise the `send`-triggered registration timing — Task 7 (real) covers that. Flag if a fake that fires on a sent prompt is worth the extra complexity.
- Codex `harness_env_args` REPLACES the Claude provider-env pinning for codex workers (different isolation lever) — confirm that's intended (it is: CODEX_HOME is codex's isolation, not the CLAUDE_CODE_* vars).
- `harness_await_ready` greps the pane for `›` — brittle if the codex TUI glyph differs by version; it's best-effort (the first send re-confirms), but note it.
