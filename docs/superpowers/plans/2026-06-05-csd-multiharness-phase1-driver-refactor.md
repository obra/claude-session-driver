# CSD Multi-Harness — Phase 1: Driver Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move Claude's harness-specific knowledge in `csd` behind a per-harness driver abstraction, with **zero Claude behavior change**, so Codex and Pi drivers can plug in later (Phases 2–3).

**Architecture:** A sourced driver file `scripts/drivers/claude.sh` implements a fixed set of *slot functions* (the seven ports from the spec). The `csd` spine calls slots and never names a harness; it loads the driver from the worker's `.meta` (`harness` field, default `claude`) or, for `launch`/`adopt`, from a new `--harness` flag (default `claude`). The existing 18-script test suite is the characterization harness: every extraction keeps it green.

**Tech Stack:** Bash, `jq`, `tmux`. Tests are standalone bash scripts run as `bash tests/test-csd-<name>.sh`; `claude` is mocked via `CSD_CLAUDE_BIN`.

**Spec:** `docs/superpowers/specs/2026-06-05-csd-multiharness-design.md`

**Out of scope (later plans):** Codex driver (Phase 2), Pi driver + `csd poll` tailer (Phase 3).

---

## File Structure

- **Create** `skills/driving-claude-code-sessions/scripts/drivers/claude.sh` — Claude driver; implements all slot functions. One responsibility: encode everything Claude-specific.
- **Modify** `skills/driving-claude-code-sessions/scripts/_lib.sh` — add `_CSD_SCRIPT_DIR`, `_load_driver`; parameterize `_CSD_WORKER_DIR`.
- **Modify** `skills/driving-claude-code-sessions/scripts/csd` — route `cmd_launch`/`cmd_adopt`/`cmd_stop`/`cmd_read_turn`/`cmd_converse` through slots; add `--harness` flag; persist `harness` in meta; load the driver in dispatch.
- **Create** `tests/test-csd-drivers.sh` — unit tests for the driver loader and Claude slot outputs.

### The slot contract (final shape after Phase 1)

```
harness_id                                    # echoes the harness id, e.g. "claude"
harness_bin                                   # echoes the resolved binary (honors CSD_<H>_BIN)
harness_control_plane                         # "hooks" | "poll"
harness_id_strategy                           # "assign" | "derive"
harness_quit_keys                             # literal keys to quit the TUI, e.g. "/exit"
harness_env_args                              # populates array WORKER_ENV_ARGS=(-e VAR=… …)
harness_launch_argv <mode> <sid> <plugin_dir> # mode=launch|resume; prints argv tokens, one per line
harness_transcript_path <sid> <cwd>           # echoes the transcript file path
harness_parse_turn <transcript> [--full]      # native JSONL -> markdown (stdout)
harness_count_text <transcript>               # echoes count of assistant text messages
harness_last_text  <transcript>               # echoes the last assistant text block
```

---

## Task 1: Driver loader + Claude manifest slots

**Files:**
- Create: `skills/driving-claude-code-sessions/scripts/drivers/claude.sh`
- Modify: `skills/driving-claude-code-sessions/scripts/_lib.sh`
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

# Load the lib + claude driver in a subshell and probe slot outputs.
probe() { ( source "$SCR/_lib.sh"; _load_driver claude; "$@" ); }

[ "$(probe harness_id)" = "claude" ] && pass "harness_id=claude" || fail "harness_id" "got $(probe harness_id)"
[ "$(probe harness_control_plane)" = "hooks" ] && pass "control_plane=hooks" || fail "control_plane" "wrong"
[ "$(probe harness_id_strategy)" = "assign" ] && pass "id_strategy=assign" || fail "id_strategy" "wrong"
[ "$(probe harness_quit_keys)" = "/exit" ] && pass "quit_keys=/exit" || fail "quit_keys" "wrong"
[ "$(probe harness_bin)" = "claude" ] && pass "bin defaults to claude" || fail "bin" "wrong"
[ "$(CSD_CLAUDE_BIN=/x/claude probe harness_bin)" = "/x/claude" ] && pass "bin honors CSD_CLAUDE_BIN" || fail "bin override" "wrong"

# Unknown harness fails loudly.
if ( source "$SCR/_lib.sh"; _load_driver nope ) 2>/dev/null; then fail "unknown driver" "should have failed"; else pass "unknown driver errors"; fi

echo "drivers: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/test-csd-drivers.sh`
Expected: FAIL — `_load_driver: command not found` (lib doesn't define it yet).

- [ ] **Step 3: Add loader + script-dir to `_lib.sh`**

At the top of `_lib.sh`, after the header comment and before `_CSD_WORKER_DIR=`, add:

```bash
# Absolute path to scripts/ (this file's directory). Used to locate drivers/.
_CSD_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the harness driver for <harness> (default claude). Driver files live at
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
# harness slot contract (see docs/superpowers/specs/2026-06-05-csd-multiharness-design.md).

harness_id()            { echo "claude"; }
harness_bin()           { echo "${CSD_CLAUDE_BIN:-claude}"; }
harness_control_plane() { echo "hooks"; }
harness_id_strategy()   { echo "assign"; }
harness_quit_keys()     { echo "/exit"; }
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash tests/test-csd-drivers.sh`
Expected: PASS — all 7 assertions, `drivers: 7 passed, 0 failed`.

- [ ] **Step 6: Verify existing suite still green** (csd doesn't call the loader yet, so nothing should change)

Run: `bash tests/test-csd-skeleton.sh && bash tests/test-csd-launch.sh`
Expected: PASS for both.

- [ ] **Step 7: Commit**

```bash
git add skills/driving-claude-code-sessions/scripts/drivers/claude.sh \
        skills/driving-claude-code-sessions/scripts/_lib.sh tests/test-csd-drivers.sh
git commit -m "refactor(csd): add driver loader + claude manifest slots (PRI-2096)"
```

---

## Task 2: Extract `harness_env_args`

Moves the provider-env pinning (`_PROVIDER_ENV_VARS` + `_build_worker_env_args`, csd lines ~665–691) into the driver. The spine calls `harness_env_args` instead.

**Files:**
- Modify: `drivers/claude.sh`
- Modify: `scripts/csd` (remove `_PROVIDER_ENV_VARS`/`_build_worker_env_args`; call `harness_env_args`)
- Test: `tests/test-csd-drivers.sh`, `tests/test-csd-provider-env.sh`

- [ ] **Step 1: Add the failing slot assertions** — append to `tests/test-csd-drivers.sh` before the final echo:

```bash
# harness_env_args populates WORKER_ENV_ARGS; SSE_PORT always pinned empty,
# an UNSET provider var is pinned empty, a SET one is left to inherit.
envprobe() { ( source "$SCR/_lib.sh"; _load_driver claude; "$@"; harness_env_args; printf '%s\n' "${WORKER_ENV_ARGS[@]}" ); }
out=$(unset CLAUDE_CODE_USE_BEDROCK; envprobe true)
echo "$out" | grep -qx -- "-e" && echo "$out" | grep -qx "CLAUDE_CODE_SSE_PORT=" && pass "env: SSE_PORT pinned" || fail "env SSE_PORT" "missing"
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
# empty when unset in this process (kills stale tmux-global values); left to
# inherit when set here (so credentials travel with the selector).
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

In `csd`, delete the `_PROVIDER_ENV_VARS=(...)` array (and its long comment block, ~lines 617–672) and the `_build_worker_env_args() { ... }` function (~lines 674–691). In `cmd_launch` and `cmd_adopt`, replace the two lines:

```bash
  local WORKER_ENV_ARGS=()
  _build_worker_env_args
```
with:
```bash
  local WORKER_ENV_ARGS=()
  harness_env_args
```

(The driver is loaded in dispatch — Task 7 — but for now add a temporary `_load_driver claude` at the top of `cmd_launch`/`cmd_adopt` just before `harness_env_args`; Task 7 removes these temporary loads when dispatch loads the driver centrally.)

- [ ] **Step 5: Run tests to verify green**

Run: `bash tests/test-csd-drivers.sh && bash tests/test-csd-provider-env.sh && bash tests/test-csd-launch.sh`
Expected: PASS for all three.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "refactor(csd): move provider-env pinning into harness_env_args slot (PRI-2096)"
```

---

## Task 3: Extract `harness_launch_argv` (launch + resume)

Moves the `claude --session-id … --plugin-dir … --dangerously-skip-permissions --disallowed-tools AskUserQuestion` construction (csd ~757–763) and the `--resume` variant (cmd_adopt ~861–876) into one slot taking a `mode` of `launch` or `resume`.

**Files:**
- Modify: `drivers/claude.sh`, `scripts/csd`
- Test: `tests/test-csd-drivers.sh`, `tests/test-csd-launch.sh`, `tests/test-csd-adopt.sh`

- [ ] **Step 1: Add failing slot assertions** — append to `tests/test-csd-drivers.sh`:

```bash
argv_launch=$( ( source "$SCR/_lib.sh"; _load_driver claude; harness_launch_argv launch SID123 /plug ) )
echo "$argv_launch" | head -1 | grep -qx "claude" && pass "launch argv starts with bin" || fail "launch argv bin" "wrong"
echo "$argv_launch" | grep -qx -- "--session-id" && echo "$argv_launch" | grep -qx "SID123" && pass "launch uses --session-id" || fail "launch sid" "wrong"
echo "$argv_launch" | grep -qx -- "--dangerously-skip-permissions" && pass "launch bypass flag" || fail "bypass" "wrong"
echo "$argv_launch" | grep -qx "AskUserQuestion" && pass "launch disallows AskUserQuestion" || fail "disallow" "wrong"
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
  local bin; bin=$(harness_bin)
  local idflag="--session-id"
  [ "$mode" = "resume" ] && idflag="--resume"
  printf '%s\n' \
    "$bin" "$idflag" "$sid" --plugin-dir "$plugin_dir" \
    --settings '{"skipDangerousModePermissionPrompt":true}' \
    --dangerously-skip-permissions \
    --disallowed-tools AskUserQuestion
}
```

- [ ] **Step 4: Route `cmd_launch` through the slot**

In `cmd_launch`, replace the `tmux new-session` block (the `local claude_bin=…` line through the closing `"${extra_args[@]+...}"`, ~754–763) with:

```bash
  local launch_argv=()
  mapfile -t launch_argv < <(harness_launch_argv launch "$session_id" "$plugin_dir")
  local WORKER_ENV_ARGS=()
  harness_env_args
  tmux new-session -d -s "$tmux_name" -c "$working_dir" \
    "${WORKER_ENV_ARGS[@]}" \
    "${launch_argv[@]}" \
    "${extra_args[@]+"${extra_args[@]}"}"
```

(Removes the now-unused `local claude_bin=…`.)

- [ ] **Step 5: Route `cmd_adopt` through the slot**

In `cmd_adopt`, both branches (`respawn-pane` and `new-session`) construct the claude argv inline. Replace the `local claude_bin=…` + `_build_worker_env_args` lines and both inline argv lists so each tmux call uses:

```bash
  local launch_argv=()
  mapfile -t launch_argv < <(harness_launch_argv resume "$session_id" "$plugin_dir")
  local WORKER_ENV_ARGS=()
  harness_env_args
```
then in the respawn branch:
```bash
    tmux respawn-pane -k -t "$tmux_name" -c "$working_dir" \
      "${WORKER_ENV_ARGS[@]}" "${launch_argv[@]}" \
      "${extra_args[@]+"${extra_args[@]}"}"
```
and the new-session branch:
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

## Task 4: Extract `harness_transcript_path`

Moves the `$HOME/.claude/projects/${cwd//\//-}/${sid}.jsonl` derivation (duplicated in `cmd_read_turn` ~298–309 and `cmd_converse` ~368–379) into one slot.

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

- [ ] **Step 3: Add the slot to `drivers/claude.sh`** (append):

```bash
# Echo the transcript path for <sid> in <cwd>. Resolves cwd to absolute first
# (matches the spine's prior behavior).
harness_transcript_path() {
  local sid="$1" cwd="$2"
  if [ -d "$cwd" ]; then cwd=$(cd "$cwd" && pwd -P); fi
  local encoded="${cwd//\//-}"
  echo "$HOME/.claude/projects/${encoded}/${sid}.jsonl"
}
```

- [ ] **Step 4: Route the spine through the slot**

In `cmd_read_turn`, replace the `cwd=…`/`encoded=…`/`log_file=…` derivation (the block computing `log_file`, ~300–309) with:

```bash
  local log_file
  log_file=$(harness_transcript_path "$sid" "$(jq -r '.cwd' "/tmp/claude-workers/${sid}.meta")")
```

In `cmd_converse`, replace the analogous `cwd=…`/`encoded=…`/`log_file=…` block (~370–379) with the same two lines (keep the separate `event_file=…` line that follows).

- [ ] **Step 5: Run tests to verify green**

Run: `bash tests/test-csd-drivers.sh && bash tests/test-csd-read-turn.sh && bash tests/test-csd-converse.sh`
Expected: PASS for all three.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "refactor(csd): move transcript-path formula into slot (PRI-2096)"
```

---

## Task 5: Extract `harness_parse_turn`, `harness_count_text`, `harness_last_text`

Moves the big `jq` turn-renderer (`cmd_read_turn` ~316–356) and the two converse helpers (`count_text_messages`, `last_text_response`, ~382–392) into the driver.

**Files:**
- Modify: `drivers/claude.sh`, `scripts/csd`
- Test: `tests/test-csd-read-turn.sh`, `tests/test-csd-converse.sh`, `tests/test-csd-readers.sh`

- [ ] **Step 1: Run the existing readers suite as the baseline (must already pass)**

Run: `bash tests/test-csd-read-turn.sh && bash tests/test-csd-readers.sh && bash tests/test-csd-converse.sh`
Expected: PASS — this is the characterization baseline this task must preserve.

- [ ] **Step 2: Add the three slots to `drivers/claude.sh`** (append). `harness_parse_turn` takes the transcript path and optional `--full`; it reproduces the current renderer verbatim (find last real user prompt line, then render assistant/user records):

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
  [ -z "$last_prompt_line" ] && return 1
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

- [ ] **Step 3: Route `cmd_read_turn` through the slot**

Replace the body of `cmd_read_turn` after `log_file` is resolved (the `if [ ! -f "$log_file" ]` check stays) — replace the `last_prompt_line=…` block plus the trailing `tail … | jq …` (~316–356) with:

```bash
  harness_parse_turn "$log_file" ${full:+--full}
```
(Keep `full` parsing at the top of `cmd_read_turn`.)

- [ ] **Step 4: Route `cmd_converse` through the slots**

In `cmd_converse`, delete the inline `count_text_messages()` and `last_text_response()` function definitions (~382–392). Replace their call sites: `before_count=$(count_text_messages)` → `before_count=$(harness_count_text "$log_file")`; `after_count=$(count_text_messages)` → `after_count=$(harness_count_text "$log_file")`; `response=$(last_text_response)` → `response=$(harness_last_text "$log_file")`.

- [ ] **Step 5: Run tests to verify green**

Run: `bash tests/test-csd-read-turn.sh && bash tests/test-csd-readers.sh && bash tests/test-csd-converse.sh && bash tests/test-csd-converse-diag.sh`
Expected: PASS for all four.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "refactor(csd): move turn parsing + converse text helpers into slots (PRI-2096)"
```

---

## Task 6: Route `cmd_stop` through `harness_quit_keys`

**Files:**
- Modify: `scripts/csd`
- Test: `tests/test-csd-stop.sh`

- [ ] **Step 1: Baseline** — Run: `bash tests/test-csd-stop.sh` → Expected: PASS.

- [ ] **Step 2: Replace the literal `/exit` in `cmd_stop`**

In `cmd_stop`, replace:
```bash
    tmux send-keys -t "$tmux_name" -l '/exit'
    tmux send-keys -t "$tmux_name" Enter
```
with:
```bash
    tmux send-keys -t "$tmux_name" -l "$(harness_quit_keys)"
    tmux send-keys -t "$tmux_name" Enter
```

- [ ] **Step 3: Run test to verify green**

Run: `bash tests/test-csd-stop.sh`
Expected: PASS (Claude's `harness_quit_keys` is `/exit`, unchanged).

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "refactor(csd): stop uses harness_quit_keys slot (PRI-2096)"
```

---

## Task 7: `--harness` flag, persist in meta, load driver in dispatch

Makes the harness a first-class, persisted axis (default `claude`), and centralizes driver loading so the temporary `_load_driver claude` calls from Task 2 are removed.

**Files:**
- Modify: `scripts/csd`
- Test: `tests/test-csd-launch.sh`, `tests/test-csd-drivers.sh`, full suite

- [ ] **Step 1: Add a failing test** — append to `tests/test-csd-drivers.sh`:

```bash
# After a launch, the meta records harness=claude (back-compat default).
# (Reuses the fake-claude pattern; minimal inline check.)
FAKE_HOME=$(mktemp -d); mkdir -p "$FAKE_HOME/.claude"; touch "$FAKE_HOME/.claude/.claude-session-driver-consent"
FAKE_CLAUDE=$(mktemp); cat > "$FAKE_CLAUDE" <<'B'
#!/bin/bash
SID=""; while [ $# -gt 0 ]; do case "$1" in --session-id) SID="$2"; shift 2;; *) shift;; esac; done
mkdir -p /tmp/claude-workers
echo "{\"ts\":\"x\",\"event\":\"session_start\",\"cwd\":\"$PWD\"}" > "/tmp/claude-workers/${SID}.events.jsonl"; exec sleep 30
B
chmod +x "$FAKE_CLAUDE"
TN="test-drivers-meta-$$"
SHIM=$(CSD_CLAUDE_BIN="$FAKE_CLAUDE" HOME="$FAKE_HOME" bash "$SCR/csd" launch "$TN" /tmp 2>/dev/null)
SID=$(basename "$(grep -l "\"tmux_name\":\"$TN\"" /tmp/claude-workers/*.meta)" .meta)
[ "$(jq -r '.harness' "/tmp/claude-workers/$SID.meta")" = "claude" ] && pass "meta records harness=claude" || fail "meta harness" "wrong"
tmux kill-session -t "$TN" 2>/dev/null || true; rm -f "/tmp/claude-workers/$SID".* "/tmp/claude-workers/bin/$TN"; rm -rf "$FAKE_HOME" "$FAKE_CLAUDE"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test-csd-drivers.sh`
Expected: FAIL — `.harness` is `null` (meta has no harness field yet).

- [ ] **Step 3: Parse `--harness` in `cmd_launch`/`cmd_adopt` and persist it**

At the top of `cmd_launch` (and `cmd_adopt`), after the existing positional parsing, add harness parsing. Simplest: support `--harness <name>` immediately after the subcommand. In the main arg parser is cleaner — add a top-level `HARNESS` var alongside `WORKER`:

In the main `while` loop that parses `--worker`, add cases:
```bash
    --harness) HARNESS="$2"; shift 2 ;;
    --harness=*) HARNESS="${1#--harness=}"; shift ;;
```
and initialize `HARNESS=""` next to `WORKER=""`.

In `cmd_launch`/`cmd_adopt`, default it: `local harness="${HARNESS:-claude}"`. Add `--arg harness "$harness"` and `harness: $harness` to the `jq -n` meta builder in both functions.

- [ ] **Step 4: Load the driver centrally in dispatch**

In the dispatch section (after `SUB`/`WORKER` are resolved, before the `case "$SUB"`), add: for per-worker subs, resolve the session and load the driver from meta; for `launch`/`adopt`, load from the flag:

```bash
if is_in "$SUB" "${PER_WORKER_SUBS[@]}"; then
  _wsid=$(resolve_session "$WORKER") || exit 1
  _whar=$(jq -r '.harness // "claude"' "/tmp/claude-workers/${_wsid}.meta" 2>/dev/null)
  _load_driver "${_whar:-claude}"
elif [ "$SUB" = "launch" ] || [ "$SUB" = "adopt" ]; then
  _load_driver "${HARNESS:-claude}"
fi
```

Then remove the temporary `_load_driver claude` lines added to `cmd_launch`/`cmd_adopt` in Task 2.

- [ ] **Step 5: Run the full suite**

Run: `for t in tests/test-*.sh; do echo "== $t =="; bash "$t" || break; done`
Expected: every script PASS.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat(csd): --harness flag, persist harness in meta, central driver load (PRI-2096)"
```

---

## Task 8: Rename worker dir to `/tmp/csd-workers` with back-compat symlink

**Files:**
- Modify: `scripts/_lib.sh`, `scripts/csd`, all `tests/test-csd-*.sh` that reference `/tmp/claude-workers`
- Test: full suite

- [ ] **Step 1: Parameterize the worker dir in `_lib.sh`**

Replace `_CSD_WORKER_DIR=/tmp/claude-workers` with:
```bash
_CSD_WORKER_DIR="${CSD_WORKER_DIR:-/tmp/csd-workers}"
```

- [ ] **Step 2: Replace hardcoded `/tmp/claude-workers` in `csd` with `$_CSD_WORKER_DIR`**

`csd` hardcodes `/tmp/claude-workers` in many places (meta/events/shim paths, `mkdir -p`). Replace each literal `/tmp/claude-workers` with `$_CSD_WORKER_DIR`. Verify none remain:
Run: `grep -n '/tmp/claude-workers' skills/driving-claude-code-sessions/scripts/csd`
Expected: no matches.

- [ ] **Step 3: Create the back-compat symlink at launch/adopt**

In both `cmd_launch` and `cmd_adopt`, where they `mkdir -p "$_CSD_WORKER_DIR" "$_CSD_WORKER_DIR/bin"`, add right after:
```bash
  # Back-compat: live workers from older csd baked /tmp/claude-workers shim paths.
  if [ "$_CSD_WORKER_DIR" = "/tmp/csd-workers" ] && [ ! -e /tmp/claude-workers ]; then
    ln -s /tmp/csd-workers /tmp/claude-workers 2>/dev/null || true
  fi
```

- [ ] **Step 4: Point the tests at the new dir**

Each integration test sets `WDIR=/tmp/claude-workers` and the fake-claude stubs write to `/tmp/claude-workers`. Update them to the canonical new path. Apply across the suite:
```bash
grep -rl '/tmp/claude-workers' tests/ | while read -r f; do
  sed -i '' 's#/tmp/claude-workers#/tmp/csd-workers#g' "$f"
done
```
(macOS `sed -i ''`. On the fake-claude heredocs the path is inside single-quoted `<<'BASH'` blocks — the sed still rewrites the literal text, which is correct since those stubs write the events file.)

- [ ] **Step 5: Run the full suite**

Run: `for t in tests/test-*.sh; do echo "== $t =="; bash "$t" || break; done`
Expected: every script PASS against `/tmp/csd-workers`.

- [ ] **Step 6: Update docs references**

In `SKILL.md` and `README.md`, the user-facing paths `/tmp/claude-workers/bin/<tmux-name>` become `/tmp/csd-workers/bin/<tmux-name>`. Update with a note that `/tmp/claude-workers` remains a back-compat symlink. (Mechanical; preserve surrounding prose.)

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "refactor(csd): rename worker dir to /tmp/csd-workers + back-compat symlink (PRI-2096)"
```

---

## Final verification

- [ ] **Run the entire suite green**

Run: `for t in tests/test-*.sh; do echo "== $t =="; bash "$t" || { echo FAILED; break; }; done`
Expected: all 19 scripts (18 existing + `test-csd-drivers.sh`) report `0 failed`.

- [ ] **Confirm zero Claude behavior change**

The only user-visible delta is the worker-dir path (`/tmp/csd-workers`, with `/tmp/claude-workers` symlinked) and the new optional `--harness` flag defaulting to `claude`. Every Claude code path runs through the same flags, transcript formula, and jq as before — now sourced from `drivers/claude.sh`.

---

## Self-Review

**Spec coverage (Phase 1 scope only):**
- Driver abstraction / slots → Tasks 1–6 (all slots extracted).
- `control_plane`/`id_strategy` manifest → Task 1.
- `--harness` selector + persisted in meta → Task 7.
- `/tmp/claude-workers` → `/tmp/csd-workers` + symlink → Task 8.
- Per-harness `harness_env_args` (was `_build_worker_env_args`) → Task 2.
- Native `parse_turn` (no canonical layer) → Task 5.
- Codex/Pi drivers, `csd poll` → **deferred to Phase 2/3 plans** (explicitly out of scope here).

**Placeholder scan:** none — every code step shows complete bash; every test step gives the exact command and expected result.

**Type/name consistency:** slot names are identical across tasks and match the contract table (`harness_id`, `harness_bin`, `harness_control_plane`, `harness_id_strategy`, `harness_quit_keys`, `harness_env_args`, `harness_launch_argv`, `harness_transcript_path`, `harness_parse_turn`, `harness_count_text`, `harness_last_text`). `WORKER_ENV_ARGS` (array out-param), `_CSD_WORKER_DIR`, `_CSD_SCRIPT_DIR`, `_load_driver` are used consistently.

**Risk flags for the reviewer:**
- Task 7's central driver-load must run *before* any `cmd_*` references a slot; confirm dispatch order.
- Task 8's `sed` rewrites paths inside fake-claude heredocs — intended, but worth a careful diff.
- `mapfile -t` (Task 3) assumes no token contains a newline; true for all current flags (the `--settings` JSON is single-line).
