# CSD Multi-Harness — Phase 3: Pi Driver + Poller Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Drive **Pi** workers through `csd` — same contract as Claude/Codex — reusing the Phase-2 derive-id spine. Pi has **no hooks**, so a `csd poll` background tailer is the control-plane *producer*: it watches Pi's session JSONL, self-registers `<sid>.meta`, and synthesizes the same `<sid>.events.jsonl` the spine already consumes.

**Architecture:** `derive` id strategy (same as Codex). The only structural difference from Codex: `harness_post_launch` starts the poller (a `csd poll` process in a second tmux window of the worker's session) instead of dismissing a trust gate. Everything else — sidecar bootstrap, dispatcher fallback, `cmd_send`/`cmd_converse` pre-registration tolerance, `_worker_tmux_name`, self-registered meta — is **reused unchanged**. **Validated end-to-end against real pi 0.75.3** (see Design notes).

**Tech Stack:** Bash 3.2 (no mapfile/assoc arrays), `jq`, `tmux`, `pi` CLI. Pi mocked in tests via `CSD_PI_BIN` → a fake that writes a session JSONL (no API).

**Spec:** `docs/superpowers/specs/2026-06-05-csd-multiharness-design.md` (Appendix A = Pi flush probe; Appendix B = derive-id flow).

**Depends on:** Phase 1 (slots) + Phase 2 (derive-id spine). **Out of scope:** changes to the assign (Claude) or Codex paths.

---

## Design notes (validated against real pi 0.75.3)

- **Launch:** interactive `pi --session-dir <wsd> --model <route> --no-extensions --no-skills` in tmux, with `PI_CODING_AGENT_DIR=<staged-auth>` + `PI_CODING_AGENT_SESSION_DIR=<wsd>`. Tools run **unattended** (no permission gate). **Quit is `/quit`.**
- **Session file:** `<wsd>/<ISO-ts>_<uuidv7>.jsonl` (flat under `--session-dir`). Line 1: `{"type":"session","version":3,"id":"<uuid>","cwd":"<abs>"}`.
- **Record → event map (proven by the prototype):**
  | session record | event |
  |---|---|
  | `{"type":"session", id, cwd}` (line 1) | self-register meta + `session_start` |
  | `message` role=`user` | `user_prompt_submit` |
  | `message` role=`assistant` `stopReason:"toolUse"` (content `toolCall`) | `pre_tool_use` |
  | `message` role=`toolResult` | `post_tool_use` |
  | `message` role=`assistant` `stopReason:"stop"` (or `error`) | `stop` |
  | tmux pane gone | `session_end` |
- **Response:** last `assistant` `message` text content (`content[].type=="text"`).
- **Model/auth:** `--model openai-codex/gpt-5.5` (or `CSD_PI_MODEL`), authenticating from a staged `~/.pi/agent` (`auth.json`).

---

## File Structure

- **Create** `scripts/drivers/pi.sh` — Pi driver slots + `harness_poll` (the tailer body).
- **Modify** `scripts/csd` — add the internal `poll` subcommand (runs `harness_poll`); no other spine changes (derive flow reused).
- **Create** `tests/fixtures/fake-pi` — writes a Pi session JSONL incrementally (no API).
- **Create** `tests/test-csd-pi.sh` — driver units + poller unit + fake-pi integration (incl. multi-turn).
- **Create** `tests/smoke-pi-real.sh` — gated real-pi multi-turn smoke.

### Slot additions

```
harness_poll <session_dir> <worker_dir> <tmux_name>   # the tailer loop (pi only)
```
`harness_control_plane` returns `"poll"`; `harness_post_launch` starts the poller.

---

## Task 1: `drivers/pi.sh` manifest + `harness_poll` (the tailer)

**Files:** `scripts/drivers/pi.sh`, `tests/test-csd-pi.sh`

- [ ] **Step 1: Write failing manifest + poller-unit tests** — `tests/test-csd-pi.sh`

```bash
#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCR="$SCRIPT_DIR/../skills/driving-claude-code-sessions/scripts"
PASS=0; FAIL=0
pass(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
fail(){ echo "  FAIL: $1 - $2"; FAIL=$((FAIL+1)); }
probe(){ ( source "$SCR/_lib.sh"; _load_driver pi; "$@" ); }

[ "$(probe harness_id)" = "pi" ] && pass "id=pi" || fail "id" "wrong"
[ "$(probe harness_control_plane)" = "poll" ] && pass "control_plane=poll" || fail "cp" "wrong"
[ "$(probe harness_id_strategy)" = "derive" ] && pass "id_strategy=derive" || fail "ids" "wrong"
[ "$(probe harness_quit_keys)" = "/quit" ] && pass "quit=/quit" || fail "quit" "wrong"

# harness_poll self-registers the meta + synthesizes events from a session file.
SD=$(mktemp -d); WDIR=$(mktemp -d)
SID="019e0000-0000-7000-8000-0000000000aa"
SF="$SD/2026-01-01T00-00-00-000Z_${SID}.jsonl"
{
  printf '{"type":"session","version":3,"id":"%s","cwd":"/w"}\n' "$SID"
  printf '{"type":"message","message":{"role":"user","content":[{"type":"text","text":"hi"}]}}\n'
  printf '{"type":"message","message":{"role":"assistant","stopReason":"toolUse","content":[{"type":"toolCall","name":"bash","arguments":{"command":"echo x"}}]}}\n'
  printf '{"type":"message","message":{"role":"toolResult","toolName":"bash","content":[{"type":"text","text":"x"}]}}\n'
  printf '{"type":"message","message":{"role":"assistant","stopReason":"stop","content":[{"type":"text","text":"PI_ANSWER"}]}}\n'
} > "$SF"
# Run the poller briefly against a NON-existent tmux session so it emits session_end and exits.
( source "$SCR/_lib.sh"; _load_driver pi; harness_poll "$SD" "$WDIR" "no-such-tmux-$$" ) >/dev/null 2>&1 || true
M=$(ls "$WDIR"/*.meta 2>/dev/null | head -1)
[ -n "$M" ] && [ "$(jq -r '.harness' "$M")" = "pi" ] && pass "poller self-registers pi meta" || fail "meta" "missing"
[ "$(jq -r '.session_id' "$M")" = "$SID" ] && pass "meta has session id from line 1" || fail "sid" "wrong"
EV="${M%.meta}.events.jsonl"
ev_seq=$(jq -r '.event' "$EV" | tr '\n' ',')
echo "$ev_seq" | grep -q 'session_start,user_prompt_submit,pre_tool_use,post_tool_use,stop' && pass "poller synthesizes the event sequence" || fail "events" "got $ev_seq"
rm -rf "$SD" "$WDIR"
echo "pi-driver: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: Run to verify it fails** — `bash tests/test-csd-pi.sh` → FAIL (no pi driver).

- [ ] **Step 3: Write `drivers/pi.sh`** (manifest + `harness_poll`, validated logic)

```bash
#!/bin/bash
# Pi (Earendil) harness driver for csd. Sourced, not executed. derive-id, but the
# control plane is a POLLER (Pi has no hooks): csd poll tails the session JSONL,
# self-registers the meta, and synthesizes the same events.jsonl. Validated
# against pi 0.75.3.

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
  for i in $(seq 1 120); do
    f=$(find "$sd" -name '*.jsonl' -type f 2>/dev/null | head -1)
    [ -n "$f" ] && break
    tmux has-session -t "$tn" 2>/dev/null || return 0
    sleep 0.5
  done
  [ -z "$f" ] && return 0
  local sid cwd
  sid=$(head -1 "$f" | jq -r '.id // empty' 2>/dev/null) || sid=""
  cwd=$(head -1 "$f" | jq -r '.cwd // empty' 2>/dev/null) || cwd=""
  [ -z "$sid" ] && return 0
  if [ ! -f "$wd/$sid.meta" ]; then
    jq -n --arg tn "$tn" --arg sid "$sid" --arg cwd "$cwd" --arg tp "$f" \
      '{tmux_name:$tn, session_id:$sid, cwd:$cwd, transcript_path:$tp, harness:"pi"}' \
      > "$wd/$sid.meta"
  fi
  local ev="$wd/$sid.events.jsonl"
  _pi_emit(){ jq -cn --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" --arg e "$1" '{ts:$ts, event:$e}' >> "$ev"; }
  _pi_emit session_start
  local prev=1 n line typ role stop
  while true; do
    n=$(wc -l < "$f" | tr -d ' ')
    if [ "$n" -gt "$prev" ]; then
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        typ=$(printf '%s' "$line" | jq -r '.type // empty' 2>/dev/null) || typ=""
        role=$(printf '%s' "$line" | jq -r '.message.role // empty' 2>/dev/null) || role=""
        stop=$(printf '%s' "$line" | jq -r '.message.stopReason // empty' 2>/dev/null) || stop=""
        case "$typ:$role:$stop" in
          message:user:*)            _pi_emit user_prompt_submit ;;
          message:assistant:toolUse) _pi_emit pre_tool_use ;;
          message:toolResult:*)      _pi_emit post_tool_use ;;
          message:assistant:stop)    _pi_emit stop ;;
          message:assistant:error)   _pi_emit stop ;;
        esac
      done < <(tail -n +"$((prev+1))" "$f")
      prev=$n
    fi
    tmux has-session -t "$tn" 2>/dev/null || { _pi_emit session_end; break; }
    sleep 0.3
  done
}
```

- [ ] **Step 4: Run the test** — `bash tests/test-csd-pi.sh` → PASS (the poller test runs against a missing tmux session so it self-registers, synthesizes, emits session_end, and exits).

- [ ] **Step 5: Commit**

```bash
git add skills/driving-claude-code-sessions/scripts/drivers/pi.sh tests/test-csd-pi.sh
git commit -m "feat(csd): pi driver manifest + harness_poll tailer (PRI-2096)"
```

---

## Task 2: Pi prepare / launch / env / post-launch (start the poller) / parser slots

**Files:** `scripts/drivers/pi.sh`, `tests/test-csd-pi.sh`

- [ ] **Step 1: Add failing slot assertions** — append to `tests/test-csd-pi.sh` (before the final echo):

```bash
# prepare stages auth + creates the session dir; launch argv has --session-dir, no --session-id
HOME_DIR=$(mktemp -d); CWD=$(mktemp -d)
( source "$SCR/_lib.sh"; _load_driver pi; CSD_PLUGIN_DIR=/plug HOME=/nonexistent harness_prepare wkr "$CWD" "$HOME_DIR" )
[ -d "$HOME_DIR/sessions" ] && pass "pi session dir created" || fail "session dir" "missing"
av=$( ( source "$SCR/_lib.sh"; _load_driver pi; harness_launch_argv launch "" "$CWD" /plug "$HOME_DIR" ) )
echo "$av" | grep -qx -- "--session-dir" && pass "pi --session-dir" || fail "--session-dir" "missing"
echo "$av" | grep -qx -- "--session-id" && fail "no sid" "should be absent" || pass "no --session-id"
ea=$( ( source "$SCR/_lib.sh"; _load_driver pi; WORKER_ENV_ARGS=(); harness_env_args; printf '%s\n' "${WORKER_ENV_ARGS[@]}" ) )
echo "$ea" | grep -q '^PI_CODING_AGENT_SESSION_DIR=' && pass "pi env session dir" || fail "env" "missing"
# parse_turn renders a pi session
SF2=$(mktemp)
printf '%s\n' \
  '{"type":"session","version":3,"id":"x","cwd":"/w"}' \
  '{"type":"message","message":{"role":"user","content":[{"type":"text","text":"hi"}]}}' \
  '{"type":"message","message":{"role":"assistant","stopReason":"stop","content":[{"type":"text","text":"PI_HELLO"}]}}' > "$SF2"
out=$( ( source "$SCR/_lib.sh"; _load_driver pi; harness_parse_turn "$SF2" ) )
echo "$out" | grep -q "PI_HELLO" && pass "pi parse_turn renders text" || fail "parse" "got: $out"
lt=$( ( source "$SCR/_lib.sh"; _load_driver pi; harness_last_text "$SF2" ) )
[ "$lt" = "PI_HELLO" ] && pass "pi last_text" || fail "last_text" "got: $lt"
rm -rf "$HOME_DIR" "$CWD" "$SF2"
```

- [ ] **Step 2: Run to verify it fails** — `bash tests/test-csd-pi.sh` → FAIL.

- [ ] **Step 3: Add the remaining slots to `drivers/pi.sh`** (append):

```bash
# Stage Pi auth into a per-worker config dir + create the session dir. The spine
# sets _CSD_CURRENT_WORKER_HOME to <worker_dir>/homes/<tmux_name>; we use it as
# PI_CODING_AGENT_DIR and put sessions under it.
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
  tmux new-window -t "$tmux_name" -n csd-poll \
    "exec '$CSD_PATH' poll pi '$sd' '$_CSD_WORKER_DIR' '$tmux_name'"
}

# derive readiness: wait for the composer, else settle (first send re-confirms).
harness_await_ready() {
  local tmux_name="$1" deadline=$((SECONDS + 20)) pane
  while [ "$SECONDS" -lt "$deadline" ]; do
    pane=$(tmux capture-pane -t "$tmux_name" -p 2>/dev/null || true)
    echo "$pane" | grep -q '%/272k\|auto)' && return 0   # pi status bar
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
```

- [ ] **Step 4: Run the test** — `bash tests/test-csd-pi.sh` → PASS.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(csd): pi prepare/launch/env/post-launch(poller)/parser slots (PRI-2096)"
```

---

## Task 3: The `csd poll` internal subcommand

**Files:** `scripts/csd`, `scripts/_lib.sh`

- [ ] **Step 1: Add `poll` to the dispatch as an internal subcommand**

In `csd`'s main dispatch, before the TOP_LEVEL/PER_WORKER classification, handle `poll` directly (it is started by the spine in a tmux window, not user-facing):

```bash
if [ "${1:-}" = "poll" ]; then
  shift
  _phar="${1:?poll <harness> <session_dir> <worker_dir> <tmux_name>}"; shift
  _load_driver "$_phar"
  harness_poll "$@"
  exit $?
fi
```
Place this immediately after `source "$SCRIPT_DIR/_lib.sh"` and the constants, before the `--worker` parse loop.

- [ ] **Step 2: Add a test** — append to `tests/test-csd-pi.sh`: run `csd poll pi <sd> <wd> <missing-tmux>` and assert it self-registers + exits.

```bash
SD3=$(mktemp -d); WD3=$(mktemp -d)
SID3="019e0000-0000-7000-8000-0000000000bb"
printf '{"type":"session","version":3,"id":"%s","cwd":"/w"}\n' "$SID3" > "$SD3/x_${SID3}.jsonl"
printf '{"type":"message","message":{"role":"assistant","stopReason":"stop","content":[{"type":"text","text":"Z"}]}}\n' >> "$SD3/x_${SID3}.jsonl"
timeout 10 bash "$SCR/csd" poll pi "$SD3" "$WD3" "no-tmux-$$" >/dev/null 2>&1 || true
[ -f "$WD3/$SID3.meta" ] && pass "csd poll self-registers" || fail "csd poll" "no meta"
rm -rf "$SD3" "$WD3"
```

- [ ] **Step 3: Run + verify** — `bash tests/test-csd-pi.sh` → PASS; full suite green.

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat(csd): csd poll internal subcommand drives harness_poll (PRI-2096)"
```

---

## Task 4: fake-pi integration test (launch → poll → read-turn → multi-turn converse)

**Files:** `tests/fixtures/fake-pi`, `tests/test-csd-pi.sh`

- [ ] **Step 1: Write `tests/fixtures/fake-pi`** — writes a session JSONL (boot turn) under `--session-dir`/`PI_CODING_AGENT_SESSION_DIR`, prints the status-bar glyphs (for await_ready), then confirms each submitted prompt with a fresh `user` record (so the poller emits `user_prompt_submit`) but no new `stop` (multi-turn regression, mirroring fake-codex).

```bash
#!/bin/bash
sd="${PI_CODING_AGENT_SESSION_DIR:-.}"
while [ $# -gt 0 ]; do case "$1" in --session-dir) sd="$2"; shift 2 ;; *) shift ;; esac; done
SID="019efake-0000-7000-8000-$(printf '%012d' "$$")"
SF="$sd/2026-01-01T00-00-00-000Z_${SID}.jsonl"; mkdir -p "$sd"
{
  printf '{"type":"session","version":3,"id":"%s","cwd":"."}\n' "$SID"
  printf '{"type":"message","message":{"role":"user","content":[{"type":"text","text":"boot"}]}}\n'
  printf '{"type":"message","message":{"role":"assistant","stopReason":"stop","content":[{"type":"text","text":"FAKE_PI_DONE"}]}}\n'
} > "$SF"
echo "0.0%/272k (auto)"   # status bar -> harness_await_ready
while IFS= read -r _line; do
  printf '{"type":"message","message":{"role":"user","content":[{"type":"text","text":"next"}]}}\n' >> "$SF"
done
```

- [ ] **Step 2: Append the integration test** to `tests/test-csd-pi.sh` (mirrors the codex integration test): launch `--harness pi` with `CSD_PI_BIN=fake-pi`, assert `read-turn` shows `FAKE_PI_DONE`, `status` idle, meta `harness=pi`, and a 2nd `converse` does **not** echo the stale boot answer.

```bash
FAKE="$SCRIPT_DIR/fixtures/fake-pi"; chmod +x "$FAKE" 2>/dev/null || true
IHOME=$(mktemp -d); mkdir -p "$IHOME/.claude" "$IHOME/.pi/agent"; touch "$IHOME/.claude/.claude-session-driver-consent"
echo '{}' > "$IHOME/.pi/agent/auth.json"
IWDIR=$(mktemp -d); ITN="test-pi-$$"; IWD=$(mktemp -d)
run_csd(){ CSD_WORKER_DIR="$IWDIR" CSD_PI_BIN="$FAKE" HOME="$IHOME" bash "$SCR/csd" "$@"; }
run_csd launch --harness pi "$ITN" "$IWD" >/dev/null 2>&1 || true
sleep 2
OUT=$(run_csd --worker "$ITN" read-turn 2>/dev/null || true)
echo "$OUT" | grep -q "FAKE_PI_DONE" && pass "pi read-turn renders the turn" || fail "pi read-turn" "got: $OUT"
ST=$(run_csd --worker "$ITN" status 2>/dev/null || true)
[ "$ST" = "idle" ] && pass "pi status idle" || fail "pi status" "got: $ST"
M=$(ls "$IWDIR"/*.meta 2>/dev/null | head -1)
[ -n "$M" ] && [ "$(jq -r '.harness' "$M")" = "pi" ] && pass "pi meta self-registered" || fail "pi meta" "missing"
OUT2=$(run_csd --worker "$ITN" converse "again" 4 2>/dev/null || true)
echo "$OUT2" | grep -q FAKE_PI_DONE && fail "pi converse stale" "echoed prior: $OUT2" || pass "pi converse not stale"
run_csd --worker "$ITN" stop >/dev/null 2>&1 || true
tmux kill-session -t "$ITN" 2>/dev/null || true
rm -rf "$IHOME" "$IWD" "$IWDIR"
```

- [ ] **Step 3: Run + full suite** — `bash tests/test-csd-pi.sh` → PASS; `for t in tests/test-*.sh; do bash "$t"; done` all green.

- [ ] **Step 4: Commit**

```bash
git add tests/fixtures/fake-pi tests/test-csd-pi.sh
git commit -m "test(csd): fake-pi integration + multi-turn regression (PRI-2096)"
```

---

## Task 5: Gated real-pi multi-turn smoke

**Files:** `tests/smoke-pi-real.sh`

- [ ] **Step 1: Write `tests/smoke-pi-real.sh`** — mirror `smoke-codex-real.sh`: self-contained HOME (consent + staged `~/.pi/agent`), `CSD_PI_BIN` = the real pi path, two `converse`s (ALPHA/BRAVO), assert turn 2 = BRAVO not stale ALPHA, then `stop`. Gate on `CSD_RUN_REAL_PI=1`.

- [ ] **Step 2: Run it once** — `CSD_RUN_REAL_PI=1 bash tests/smoke-pi-real.sh` → multi-turn pi conversation drives through csd.

- [ ] **Step 3: Commit**

```bash
git add tests/smoke-pi-real.sh
git commit -m "test(csd): gated real-pi multi-turn smoke (PRI-2096)"
```

---

## Final verification
- [ ] Full suite green (22 scripts incl. test-csd-pi.sh) from a clean slate.
- [ ] Real-pi smoke passed once.
- [ ] `csd launch --harness pi <name> <cwd>` → multi-turn `converse` → `read-turn` → `stop` works against real pi.
- [ ] Claude + Codex paths unchanged (all prior tests green).

## Self-Review
- **Spec coverage:** poller control plane → Tasks 1,3; record→event map (Appendix A/prototype) → Task 1; derive launch via poller-in-tmux-window → Task 2; multi-turn regression → Task 4; real validation → Task 5.
- **Reused from Phase 2 (no change):** derive `cmd_launch` branch, sidecar+dispatcher fallback, `cmd_send`/`cmd_converse` pre-registration, `_worker_tmux_name`, `cmd_stop` cleanup, `cmd_adopt` reject.
- **Risks for the reviewer:** (1) `harness_poll`'s per-line `jq` in a `set -e` driver — confirm the `|| ""` guards hold and a malformed `message_update` line (Pi can emit multi-MB lines) doesn't abort the loop. (2) `harness_post_launch` starts the poller in a tmux *window* — confirm `kill-session` reaps it and `cmd_stop`'s `_worker_tmux_name` still resolves. (3) the poller and `cmd_send` both consult the events file — confirm no race on first registration. (4) `harness_await_ready` greps the pi status bar — brittle across versions (best-effort, first send re-confirms). (5) Pi may emit `message_update` cumulative-state records in some modes; confirm the native (non-`--mode json`) interactive format used here only emits discrete `message` records (the prototype showed it does).
