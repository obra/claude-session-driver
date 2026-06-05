# CSD Multi-Harness — Phase 1: Driver Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move Claude's harness-specific knowledge in `csd` behind a per-harness driver abstraction, with **zero Claude behavior change**, so Codex and Pi drivers can plug in later (Phases 2–3).

**Architecture:** A sourced driver file `scripts/drivers/claude.sh` implements a fixed set of *slot functions* (the seven ports from the spec). The `csd` spine calls slots and never names a harness; the dispatch layer loads the driver from the worker's `.meta` (`harness` field, default `claude`) or, for `launch`/`adopt`, defaults to `claude` (a `--harness` flag is added in Task 8). The existing 18-script bash test suite is the characterization harness: every extraction keeps it green.

**Tech Stack:** Bash **3.2** (`/bin/bash` on macOS — NO `mapfile`, NO associative arrays), `jq`, `tmux`. Tests are standalone bash scripts run as `bash tests/test-csd-<name>.sh`; `claude` is mocked via `CSD_CLAUDE_BIN`.

**Spec:** `docs/superpowers/specs/2026-06-05-csd-multiharness-design.md`

**Out of scope (later plans):** Codex driver (Phase 2), Pi driver + `csd poll` tailer (Phase 3).

**Reviewer-found constraints baked into this revision (Riker@c9ac5ed5):**
- `/bin/bash` is 3.2.57 — `mapfile` is absent; use a `while read` loop to collect argv.
- `full` is the *string* `true`/`false`; `${full:+--full}` is wrong (always non-empty). Guard with `[ "$full" = true ]`.
- The driver must be loaded **before** any per-worker command calls a slot → central load is Task 1.
- `hooks/emit-event` hardcodes `/tmp/claude-workers` (4 sites) and must be migrated in the rename task.
- `/tmp/claude-workers` already exists as a real dir → the back-compat symlink must handle that.
- `csd` has 31 literal `/tmp/claude-workers` sites and uses `$_CSD_WORKER_DIR` nowhere → parameterize early (Task 2), flip the default late (Task 9).

---

## File Structure

- **Create** `skills/driving-claude-code-sessions/scripts/drivers/claude.sh` — Claude driver; all slot functions.
- **Modify** `skills/driving-claude-code-sessions/scripts/_lib.sh` — add `_CSD_SCRIPT_DIR`, `_load_driver`; (Task 9) flip `_CSD_WORKER_DIR` default.
- **Modify** `skills/driving-claude-code-sessions/scripts/csd` — central driver load in dispatch; route launch/adopt/stop/read-turn/converse through slots; parameterize worker-dir; add `--harness`.
- **Modify** `hooks/emit-event` — (Task 9) parameterize worker-dir.
- **Create** `tests/test-csd-drivers.sh` — unit tests for the loader and Claude slot outputs.

### The slot contract (final shape after Phase 1)

```
harness_id                                    # echoes "claude"
harness_bin                                   # echoes ${CSD_CLAUDE_BIN:-claude}
harness_control_plane                         # "hooks" | "poll"
harness_id_strategy                           # "assign" | "derive"
harness_quit_keys                             # literal TUI quit keys, e.g. "/exit"
harness_env_args                              # populates array WORKER_ENV_ARGS=(-e VAR=… …)
harness_launch_argv <mode> <sid> <plugin_dir> # mode=launch|resume; prints argv tokens, one per line
harness_transcript_path <sid> <cwd>           # echoes the transcript file path
harness_parse_turn <transcript> [--full]      # native JSONL -> markdown (stdout)
harness_count_text <transcript>               # echoes count of assistant text messages
harness_last_text  <transcript>               # echoes the last assistant text block
```

---

## Task 1: Driver loader, manifest slots, and central dispatch load

Establishes the loader and loads the driver in dispatch **before** any command runs, so later tasks can route per-worker commands through slots safely.

**Files:**
- Create: `scripts/drivers/claude.sh`
- Modify: `scripts/_lib.sh`, `scripts/csd`
- Test: `tests/test-csd-drivers.sh`

- [ ] **Step 1: Write the failing test** — `tests/test-csd-drivers.sh`

```bash
#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCR="$SCRIPT_DIR/../skills/driving-claude-code-sessions/scripts"
PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1 - $2"; FAIL=$((FAIL+1)); }
probe() { ( source "$SCR/_lib.sh"; _load_driver claude; "$@" ); }

[ "$(probe harness_id)" = "claude" ] && pass "harness_id=claude" || fail "harness_id" "got $(probe harness_id)"
[ "$(probe harness_control_plane)" = "hooks" ] && pass "control_plane=hooks" || fail "control_plane" "wrong"
[ "$(probe harness_id_strategy)" = "assign" ] && pass "id_strategy=assign" || fail "id_strategy" "wrong"
[ "$(probe harness_quit_keys)" = "/exit" ] && pass "quit_keys=/exit" || fail "quit_keys" "wrong"
[ "$(probe harness_bin)" = "claude" ] && pass "bin defaults to claude" || fail "bin" "wrong"
[ "$(CSD_CLAUDE_BIN=/x/claude probe harness_bin)" = "/x/claude" ] && pass "bin honors CSD_CLAUDE_BIN" || fail "bin override" "wrong"
if ( source "$SCR/_lib.sh"; _load_driver nope ) 2>/dev/null; then fail "unknown driver" "should fail"; else pass "unknown driver errors"; fi

echo "drivers: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/test-csd-drivers.sh`
Expected: FAIL — `_load_driver: command not found`.

- [ ] **Step 3: Add loader + script-dir to `_lib.sh`**

After the header comment, before `_CSD_WORKER_DIR=`, add:

```bash
# Absolute path to scripts/ (this file's dir). Used to locate drivers/.
_CSD_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the harness driver for <harness> (default claude). Drivers live at
# scripts/drivers/<harness>.sh and define the harness slot functions.
_load_driver() {
  local harness="${1:-claude}"
  local driver_file="$_CSD_SCRIPT_DIR/drivers/${harness}.sh"
  if [ ! -f "$driver_file" ]; then
    echo "Error: no driver for harness '$harness' (expected $driver_file)" >&2
    return 1
  fi
  # shellcheck source=/dev/null
  source "$driver_file"
}
```

- [ ] **Step 4: Create `drivers/claude.sh` with the manifest slots**

```bash
#!/bin/bash
# Claude Code harness driver for csd. Sourced, not executed. Implements the
# harness slot contract (docs/superpowers/specs/2026-06-05-csd-multiharness-design.md).

harness_id()            { echo "claude"; }
harness_bin()           { echo "${CSD_CLAUDE_BIN:-claude}"; }
harness_control_plane() { echo "hooks"; }
harness_id_strategy()   { echo "assign"; }
harness_quit_keys()     { echo "/exit"; }
```

- [ ] **Step 5: Load the driver centrally in dispatch**

In `csd`, after the SUB/WORKER validation block and the `shift` that consumes the subcommand (just before `case "$SUB" in`), insert:

```bash
# Load the harness driver before dispatching. Per-worker subs read the harness
# from the worker meta (default claude); launch/adopt default to claude here
# (Task 8 adds the --harness flag + per-command override).
if is_in "$SUB" "${PER_WORKER_SUBS[@]}"; then
  _wsid=$(resolve_session "$WORKER") || exit 1
  _whar=$(jq -r '.harness // "claude"' "/tmp/claude-workers/${_wsid}.meta" 2>/dev/null)
  _load_driver "${_whar:-claude}"
elif [ "$SUB" = "launch" ] || [ "$SUB" = "adopt" ]; then
  _load_driver claude
fi
```

(Uses literal `/tmp/claude-workers` for now; Task 2 parameterizes it.)

- [ ] **Step 6: Run the driver test + full suite**

Run: `bash tests/test-csd-drivers.sh`
Expected: PASS — `drivers: 7 passed, 0 failed`.
Run: `for t in tests/test-csd-*.sh; do bash "$t" >/dev/null && echo "ok $t" || echo "FAIL $t"; done`
Expected: every script `ok` (driver load is a no-op for behavior; slots aren't called yet).

- [ ] **Step 7: Commit**

```bash
git add skills/driving-claude-code-sessions/scripts/drivers/claude.sh \
        skills/driving-claude-code-sessions/scripts/_lib.sh \
        skills/driving-claude-code-sessions/scripts/csd tests/test-csd-drivers.sh
git commit -m "refactor(csd): driver loader, claude manifest slots, central load (PRI-2096)"
```

---

## Task 2: Parameterize the worker dir to `$_CSD_WORKER_DIR` (zero behavior change)

`_lib.sh` already defines `_CSD_WORKER_DIR=/tmp/claude-workers`, but `csd` never uses it (31 literal sites). Convert them now while the value is unchanged, so Task 9 only flips the default.

**Files:**
- Modify: `scripts/csd`
- Test: full suite

- [ ] **Step 1: Replace runtime literals with the variable**

In `csd`, replace every `/tmp/claude-workers` with `$_CSD_WORKER_DIR`. This includes the `usage()` heredoc (it is an **unquoted** `cat <<EOF`, so the variable expands and help text stays accurate) and the doubled occurrences in `mkdir -p /tmp/claude-workers /tmp/claude-workers/bin` (both → `$_CSD_WORKER_DIR`). Also update the dispatch block from Task 1.

Apply, then verify none remain:
```bash
sed -i '' 's#/tmp/claude-workers#$_CSD_WORKER_DIR#g' skills/driving-claude-code-sessions/scripts/csd
grep -n '/tmp/claude-workers' skills/driving-claude-code-sessions/scripts/csd
```
Expected: no matches.

- [ ] **Step 2: Sanity-check the shim heredoc didn't get clobbered**

`_write_worker_shim` writes a shim via `cat > "$shim_path" <<EOF` containing `exec "$CSD_PATH" --worker …` — it has no worker-dir path, so it's untouched. Confirm the shim still execs csd:
```bash
grep -n 'exec "\$CSD_PATH"' skills/driving-claude-code-sessions/scripts/csd
```
Expected: the exec line is intact.

- [ ] **Step 3: Run the full suite**

Run: `for t in tests/test-*.sh; do bash "$t" >/dev/null && echo "ok $t" || echo "FAIL $t"; done`
Expected: every script `ok` (`_CSD_WORKER_DIR` is still `/tmp/claude-workers`).

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "refactor(csd): use \$_CSD_WORKER_DIR instead of literal path (PRI-2096)"
```

---

## Task 3: Extract `harness_env_args`

Moves provider-env pinning (`_PROVIDER_ENV_VARS` at csd:665, `_build_worker_env_args` at csd:678) into the driver.

**Files:**
- Modify: `drivers/claude.sh`, `scripts/csd`
- Test: `tests/test-csd-drivers.sh`, `tests/test-csd-provider-env.sh`, `tests/test-csd-launch.sh`

- [ ] **Step 1: Add failing slot assertions** — append to `tests/test-csd-drivers.sh` before the final echo:

```bash
envprobe() { ( source "$SCR/_lib.sh"; _load_driver claude; "$@"; harness_env_args; printf '%s\n' "${WORKER_ENV_ARGS[@]}" ); }
out=$(unset CLAUDE_CODE_USE_BEDROCK; envprobe true)
echo "$out" | grep -qx "CLAUDE_CODE_SSE_PORT=" && pass "env: SSE_PORT pinned" || fail "env SSE_PORT" "missing"
echo "$out" | grep -qx "CLAUDE_CODE_USE_BEDROCK=" && pass "env: unset bedrock pinned empty" || fail "env bedrock unset" "missing"
out2=$(CLAUDE_CODE_USE_BEDROCK=1 envprobe true)
echo "$out2" | grep -qx "CLAUDE_CODE_USE_BEDROCK=" && fail "env set-bedrock" "should NOT pin a set var" || pass "env: set bedrock left to inherit"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test-csd-drivers.sh`
Expected: FAIL — `harness_env_args: command not found`.

- [ ] **Step 3: Add `harness_env_args` to `drivers/claude.sh`** (append):

```bash
# Provider/auth vars Claude resolves from the process env (issue #18). Pinned
# empty when unset here (kills stale tmux-global values); left to inherit when
# set here (so credentials travel with the selector).
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
```

- [ ] **Step 4: Remove the originals from `csd` and call the slot**

Delete the `_PROVIDER_ENV_VARS=(...)` array + its comment block (csd ~617–672) and the `_build_worker_env_args() { ... }` function (csd ~674–691). In `cmd_launch` and `cmd_adopt`, both already call `_build_worker_env_args` after `local WORKER_ENV_ARGS=()`; replace each `_build_worker_env_args` call with `harness_env_args`. (The driver is already loaded centrally — Task 1 — for launch/adopt, so no per-function load is needed.)

- [ ] **Step 5: Run tests to verify green**

Run: `bash tests/test-csd-drivers.sh && bash tests/test-csd-provider-env.sh && bash tests/test-csd-launch.sh && bash tests/test-csd-adopt.sh`
Expected: PASS for all four.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "refactor(csd): move provider-env pinning into harness_env_args slot (PRI-2096)"
```

---

## Task 4: Extract `harness_launch_argv` (launch + resume), bash-3.2 safe

Moves the `claude --session-id …` construction (csd:757) and the `--resume` variant (cmd_adopt:861–876) into one slot. **No `mapfile`** — collect with a read loop.

**Files:**
- Modify: `drivers/claude.sh`, `scripts/csd`
- Test: `tests/test-csd-drivers.sh`, `tests/test-csd-launch.sh`, `tests/test-csd-adopt.sh`

- [ ] **Step 1: Add failing slot assertions** — append to `tests/test-csd-drivers.sh`:

```bash
argv_launch=$( ( source "$SCR/_lib.sh"; _load_driver claude; harness_launch_argv launch SID123 /plug ) )
[ "$(echo "$argv_launch" | head -1)" = "claude" ] && pass "launch argv starts with bin" || fail "launch argv bin" "wrong"
echo "$argv_launch" | grep -qx -- "--session-id" && echo "$argv_launch" | grep -qx "SID123" && pass "launch uses --session-id" || fail "launch sid" "wrong"
echo "$argv_launch" | grep -qx -- "--dangerously-skip-permissions" && pass "launch bypass flag" || fail "bypass" "wrong"
echo "$argv_launch" | grep -qx "AskUserQuestion" && pass "launch disallows AskUserQuestion" || fail "disallow" "wrong"
# The --settings JSON survives as ONE token.
echo "$argv_launch" | grep -qFx '{"skipDangerousModePermissionPrompt":true}' && pass "settings is one token" || fail "settings token" "split"
argv_resume=$( ( source "$SCR/_lib.sh"; _load_driver claude; harness_launch_argv resume SID123 /plug ) )
echo "$argv_resume" | grep -qx -- "--resume" && pass "resume uses --resume" || fail "resume" "wrong"
echo "$argv_resume" | grep -qx -- "--session-id" && fail "resume sid" "should not use --session-id" || pass "resume omits --session-id"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test-csd-drivers.sh`
Expected: FAIL — `harness_launch_argv: command not found`.

- [ ] **Step 3: Add `harness_launch_argv` to `drivers/claude.sh`** (append):

```bash
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
```

- [ ] **Step 4: Route `cmd_launch` through the slot (read loop, not mapfile)**

In `cmd_launch`, replace the `local claude_bin=…` line and the `tmux new-session … "${extra_args[@]+...}"` block (csd ~754–763) with:

```bash
  local launch_argv=()
  while IFS= read -r _tok; do launch_argv+=("$_tok"); done \
    < <(harness_launch_argv launch "$session_id" "$plugin_dir")
  local WORKER_ENV_ARGS=()
  harness_env_args
  tmux new-session -d -s "$tmux_name" -c "$working_dir" \
    "${WORKER_ENV_ARGS[@]}" \
    "${launch_argv[@]}" \
    "${extra_args[@]+"${extra_args[@]}"}"
```

- [ ] **Step 5: Route `cmd_adopt` through the slot**

In `cmd_adopt`, replace the `local claude_bin=…` + `_build_worker_env_args` lines (already `harness_env_args` after Task 3) and BOTH inline argv lists. Before the `if tmux has-session` branch, build once:

```bash
  local launch_argv=()
  while IFS= read -r _tok; do launch_argv+=("$_tok"); done \
    < <(harness_launch_argv resume "$session_id" "$plugin_dir")
  local WORKER_ENV_ARGS=()
  harness_env_args
```
respawn branch:
```bash
    tmux respawn-pane -k -t "$tmux_name" -c "$working_dir" \
      "${WORKER_ENV_ARGS[@]}" "${launch_argv[@]}" \
      "${extra_args[@]+"${extra_args[@]}"}"
```
new-session branch:
```bash
    tmux new-session -d -s "$tmux_name" -c "$working_dir" \
      "${WORKER_ENV_ARGS[@]}" "${launch_argv[@]}" \
      "${extra_args[@]+"${extra_args[@]}"}"
```

- [ ] **Step 6: Run tests to verify green**

Run: `bash tests/test-csd-drivers.sh && bash tests/test-csd-launch.sh && bash tests/test-csd-adopt.sh`
Expected: PASS for all three.

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "refactor(csd): route launch/adopt through harness_launch_argv slot (PRI-2096)"
```

---

## Task 5: Extract `harness_transcript_path` (preserve the null-cwd guard)

Moves the path formula (csd:300–309 in read-turn, 370–379 in converse) into the slot. The null-cwd guard stays in the callers (a behavior the original has and tests rely on for the error message).

**Files:**
- Modify: `drivers/claude.sh`, `scripts/csd`
- Test: `tests/test-csd-drivers.sh`, `tests/test-csd-read-turn.sh`, `tests/test-csd-converse.sh`

- [ ] **Step 1: Add failing assertion** — append to `tests/test-csd-drivers.sh`:

```bash
tp=$( ( source "$SCR/_lib.sh"; _load_driver claude; HOME=/home/x harness_transcript_path SID /a/b ) )
[ "$tp" = "/home/x/.claude/projects/-a-b/SID.jsonl" ] && pass "transcript_path formula" || fail "transcript_path" "got $tp"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test-csd-drivers.sh`
Expected: FAIL — `harness_transcript_path: command not found`.

- [ ] **Step 3: Add the slot to `drivers/claude.sh`** (append). Keeps the `cd && pwd -P` resolution the spine did:

```bash
# Echo the transcript path for <sid> in <cwd> (cwd resolved to absolute first).
harness_transcript_path() {
  local sid="$1" cwd="$2"
  if [ -d "$cwd" ]; then cwd=$(cd "$cwd" && pwd -P); fi
  local encoded="${cwd//\//-}"
  echo "$HOME/.claude/projects/${encoded}/${sid}.jsonl"
}
```

- [ ] **Step 4: Route the spine, keeping the null-cwd guard**

In `cmd_read_turn`, the block (csd:300–309) reads `cwd` from meta, guards null, resolves `cwd`, builds `encoded`/`log_file`. Replace the `encoded=…`/`log_file=…` tail (keep the `cwd=$(jq …)` read and the `if [ -z "$cwd" ] || [ "$cwd" = "null" ]` guard) with:

```bash
  log_file=$(harness_transcript_path "$sid" "$cwd")
```
(Delete the now-duplicate `if [ -d "$cwd" ]; then cwd=$(cd "$cwd" && pwd -P); fi` and `encoded=…` lines — the slot does both.)

Apply the identical change in `cmd_converse` (csd:370–379), keeping its own null-cwd guard and the separate `event_file=…` line.

- [ ] **Step 5: Run tests to verify green**

Run: `bash tests/test-csd-drivers.sh && bash tests/test-csd-read-turn.sh && bash tests/test-csd-converse.sh`
Expected: PASS for all three.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "refactor(csd): move transcript-path formula into slot (PRI-2096)"
```

---

## Task 6: Extract `harness_parse_turn`, `harness_count_text`, `harness_last_text`

Moves the jq turn-renderer (csd:316–356) and the converse helpers (`count_text_messages` csd:382, `last_text_response` csd:389) into the driver. **Fixes the `${full:+--full}` bug** at the call site.

**Files:**
- Modify: `drivers/claude.sh`, `scripts/csd`
- Test: `tests/test-csd-read-turn.sh`, `tests/test-csd-converse.sh`, `tests/test-csd-readers.sh`

- [ ] **Step 1: Baseline (must already pass)**

Run: `bash tests/test-csd-read-turn.sh && bash tests/test-csd-readers.sh && bash tests/test-csd-converse.sh`
Expected: PASS — the characterization baseline this task preserves (including the truncate-to-5-lines assertion).

- [ ] **Step 2: Add the three slots to `drivers/claude.sh`** (append). `harness_parse_turn` preserves the original's "no user prompt" stderr message:

```bash
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
```

- [ ] **Step 3: Route `cmd_read_turn` through the slot — correct `--full` handling**

After `log_file` is resolved and the `if [ ! -f "$log_file" ]` check, replace the `last_prompt_line=…` block + trailing `tail … | jq …` (csd:316–356) with:

```bash
  local parse_full=()
  [ "$full" = true ] && parse_full=(--full)
  harness_parse_turn "$log_file" "${parse_full[@]+"${parse_full[@]}"}"
```

- [ ] **Step 4: Route `cmd_converse` through the slots**

Delete the inline `count_text_messages()` and `last_text_response()` definitions (csd:382–392). Replace call sites: `before_count=$(count_text_messages)` → `before_count=$(harness_count_text "$log_file")`; `after_count=$(count_text_messages)` → `after_count=$(harness_count_text "$log_file")`; `response=$(last_text_response)` → `response=$(harness_last_text "$log_file")`.

- [ ] **Step 5: Run tests to verify green (incl. truncation assertion)**

Run: `bash tests/test-csd-read-turn.sh && bash tests/test-csd-readers.sh && bash tests/test-csd-converse.sh && bash tests/test-csd-converse-diag.sh`
Expected: PASS for all four — in particular the read-turn truncation/footer assertions (which would fail if `--full` were always passed).

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "refactor(csd): move turn parsing + converse text helpers into slots (PRI-2096)"
```

---

## Task 7: Route `cmd_stop` through `harness_quit_keys`

**Files:**
- Modify: `scripts/csd`
- Test: `tests/test-csd-stop.sh`

- [ ] **Step 1: Baseline** — Run: `bash tests/test-csd-stop.sh` → Expected: PASS.

- [ ] **Step 2: Replace the literal `/exit` in `cmd_stop` (csd:507)**

```bash
    tmux send-keys -t "$tmux_name" -l "$(harness_quit_keys)"
    tmux send-keys -t "$tmux_name" Enter
```

- [ ] **Step 3: Run test** — Run: `bash tests/test-csd-stop.sh` → Expected: PASS (Claude's quit keys are `/exit`, unchanged).

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "refactor(csd): stop uses harness_quit_keys slot (PRI-2096)"
```

---

## Task 8: `--harness` flag (after the subcommand), persist in meta

Adds the harness selector matching the spec's syntax `csd launch --harness codex <name> <cwd>` (flag after the subcommand), persists it in meta, and re-loads the chosen driver.

**Files:**
- Modify: `scripts/csd`
- Test: `tests/test-csd-drivers.sh`, full suite

- [ ] **Step 1: Add a failing test** — append to `tests/test-csd-drivers.sh`:

```bash
FAKE_HOME=$(mktemp -d); mkdir -p "$FAKE_HOME/.claude"; touch "$FAKE_HOME/.claude/.claude-session-driver-consent"
FAKE_CLAUDE=$(mktemp); cat > "$FAKE_CLAUDE" <<'B'
#!/bin/bash
SID=""; while [ $# -gt 0 ]; do case "$1" in --session-id) SID="$2"; shift 2;; *) shift;; esac; done
mkdir -p /tmp/csd-workers
echo "{\"ts\":\"x\",\"event\":\"session_start\",\"cwd\":\"$PWD\"}" > "/tmp/csd-workers/${SID}.events.jsonl"; exec sleep 30
B
chmod +x "$FAKE_CLAUDE"
TN="test-drivers-meta-$$"
CSD_CLAUDE_BIN="$FAKE_CLAUDE" HOME="$FAKE_HOME" bash "$SCR/csd" launch "$TN" /tmp >/dev/null 2>&1
META=$(grep -l "\"tmux_name\":\"$TN\"" /tmp/csd-workers/*.meta)
[ "$(jq -r '.harness' "$META")" = "claude" ] && pass "meta records harness=claude" || fail "meta harness" "got $(jq -r '.harness' "$META")"
SID=$(basename "$META" .meta)
tmux kill-session -t "$TN" 2>/dev/null || true; rm -f "/tmp/csd-workers/$SID".* "/tmp/csd-workers/bin/$TN"; rm -rf "$FAKE_HOME" "$FAKE_CLAUDE"
```

(Uses `/tmp/csd-workers` — the path after Task 9. If running Task 8 before Task 9, temporarily use `/tmp/claude-workers`; the suite is re-run after Task 9 regardless.)

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test-csd-drivers.sh`
Expected: FAIL — `.harness` is `null`.

- [ ] **Step 3: Parse a leading `--harness` in `cmd_launch` and `cmd_adopt`**

At the very top of `cmd_launch` (before reading positional `tmux_name`), add:

```bash
  local harness="claude"
  while [ "${1:-}" = "--harness" ] || [[ "${1:-}" == --harness=* ]]; do
    if [ "$1" = "--harness" ]; then harness="$2"; shift 2; else harness="${1#--harness=}"; shift; fi
  done
  _load_driver "$harness"
```
Add the identical block at the top of `cmd_adopt`. (`_load_driver "$harness"` re-sources over the dispatch default; last source wins.)

- [ ] **Step 4: Persist `harness` in the meta**

In both `cmd_launch` and `cmd_adopt`, the `jq -n` meta builder gets a new arg + field: add `--arg harness "$harness"` and `harness: $harness,` to the object.

- [ ] **Step 5: Run the full suite**

Run: `for t in tests/test-*.sh; do bash "$t" >/dev/null && echo "ok $t" || echo "FAIL $t"; done`
Expected: every script `ok` (existing launches omit `--harness` → default `claude`).

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat(csd): --harness flag + persist harness in meta (PRI-2096)"
```

---

## Task 9: Rename worker dir to `/tmp/csd-workers` (flip default, migrate emit-event, symlink)

**Files:**
- Modify: `scripts/_lib.sh`, `hooks/emit-event`, all `tests/*.sh` referencing the path, `scripts/csd` (launch/adopt symlink), `SKILL.md`, `README.md`
- Test: full suite + `test-emit-event.sh`

- [ ] **Step 1: Flip the default in `_lib.sh`**

Replace `_CSD_WORKER_DIR="${CSD_WORKER_DIR:-/tmp/claude-workers}"` — i.e. change the current `_CSD_WORKER_DIR=/tmp/claude-workers` to:
```bash
_CSD_WORKER_DIR="${CSD_WORKER_DIR:-/tmp/csd-workers}"
```

- [ ] **Step 2: Parameterize `hooks/emit-event`** (it does not source `_lib.sh`)

Replace its 3 runtime sites (emit-event:34, 51, 72 — the comment on line 6 may stay or update). Add near the top (after the `set` line):
```bash
WORKER_DIR="${CSD_WORKER_DIR:-/tmp/csd-workers}"
```
Then: line 34 `if [ ! -f "$WORKER_DIR/${SESSION_ID}.meta" ]; then`; line 51 `mkdir -p "$WORKER_DIR"`; line 72 `EVENT_FILE="$WORKER_DIR/${SESSION_ID}.events.jsonl"`.

- [ ] **Step 3: Back-compat symlink that respects an existing real dir**

In `cmd_launch` and `cmd_adopt`, right after `mkdir -p "$_CSD_WORKER_DIR" "$_CSD_WORKER_DIR/bin"`, add:

```bash
  # Best-effort back-compat: only symlink the legacy path when it doesn't already
  # exist (a leftover real /tmp/claude-workers dir from older csd is left alone;
  # relaunch any live pre-upgrade workers after this upgrade).
  if [ "$_CSD_WORKER_DIR" = "/tmp/csd-workers" ] && [ ! -e /tmp/claude-workers ]; then
    ln -s /tmp/csd-workers /tmp/claude-workers 2>/dev/null || true
  fi
```

- [ ] **Step 4: Point the tests at the new dir**

Rewrite the path across all 16 referencing test files (including `test-csd-converse-diag.sh` and `test-csd-integration.sh`, and the fake-claude heredocs that write the events file):
```bash
grep -rl '/tmp/claude-workers' tests/ | while read -r f; do
  sed -i '' 's#/tmp/claude-workers#/tmp/csd-workers#g' "$f"
done
grep -rn '/tmp/claude-workers' tests/ || echo "tests clean"
```
Expected: `tests clean`.

- [ ] **Step 5: Run the full suite (including emit-event) on a clean machine**

```bash
rm -rf /tmp/csd-workers   # ensure no stale state masks a bug
for t in tests/test-*.sh; do bash "$t" >/dev/null && echo "ok $t" || echo "FAIL $t"; done
```
Expected: every script `ok` — especially `test-emit-event.sh` (now writes/reads `/tmp/csd-workers`) and `test-csd-launch.sh`.

- [ ] **Step 6: Update user-facing docs**

In `SKILL.md` and `README.md`, change `/tmp/claude-workers/bin/<tmux-name>` → `/tmp/csd-workers/bin/<tmux-name>`, adding a one-line note that `/tmp/claude-workers` remains a best-effort back-compat symlink. Preserve surrounding prose.

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "refactor(csd): rename worker dir to /tmp/csd-workers + migrate emit-event (PRI-2096)"
```

---

## Final verification

- [ ] **Whole suite green from a clean slate**

```bash
rm -rf /tmp/csd-workers
for t in tests/test-*.sh; do echo "== $t =="; bash "$t" || { echo FAILED; break; }; done
```
Expected: all 19 scripts (18 existing + `test-csd-drivers.sh`) report `0 failed`.

- [ ] **Confirm zero Claude behavior change**

Only user-visible deltas: the worker-dir path (`/tmp/csd-workers`, legacy symlinked best-effort) and the new optional `--harness` flag (default `claude`). Every Claude code path runs the same flags, transcript formula, and jq as before — now sourced from `drivers/claude.sh`.

---

## Self-Review

**Spec coverage (Phase 1 scope):** slots → Tasks 1,3,4,5,6,7; manifest (`control_plane`/`id_strategy`) → Task 1; `--harness` persisted in meta → Task 8; dir rename + symlink → Task 9; `harness_env_args` → Task 3; native `parse_turn` (no canonical layer) → Task 6. Codex/Pi drivers + `csd poll` → deferred to Phase 2/3 plans (out of scope).

**Placeholder scan:** none — every code step is complete; every test step gives the command + expected result.

**Type/name consistency:** slot names match the contract table across all tasks. `WORKER_ENV_ARGS`, `_CSD_WORKER_DIR`, `_CSD_SCRIPT_DIR`, `_load_driver`, `launch_argv`, `parse_full` used consistently.

**Reviewer blockers resolved:** (1) `mapfile` → `while read` loop (Task 4). (2) `${full:+--full}` → `[ "$full" = true ]` array guard (Task 6 Step 3). (3) central driver-load moved to Task 1, before any per-worker slot routing. (4) `emit-event` migrated in Task 9 Step 2. (5) symlink guard documented to leave an existing real dir alone (Task 9 Step 3). (6) worker-dir parameterized to `$_CSD_WORKER_DIR` early (Task 2), default flipped late (Task 9 Step 1). Nit (4) `--harness` parsed after the subcommand to match the spec (Task 8 Step 3). Nits (1)(2): null-cwd guard kept in callers (Task 5), no-prompt stderr kept in the slot (Task 6).

**Residual risk for the executor:** Task 9 must run from a clean `/tmp/csd-workers` (Step 5 removes it first) so a leftover dir can't mask a path bug; the legacy `/tmp/claude-workers` real dir on dev machines means the symlink is intentionally skipped there.
```
