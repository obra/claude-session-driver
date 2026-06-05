# CSD Multi-Harness Support — Design

- **Date:** 2026-06-05
- **Status:** Approved (design); ready for implementation plan
- **Author:** Kaylee@a55760bc
- **Topic:** Let CSD drive Codex and Pi workers alongside Claude Code

## Goal

Today CSD (claude-session-driver) drives exactly one harness: Claude Code. This
design generalizes it to drive **OpenAI Codex** and **Pi** workers through the
same CLI, the same tmux model, and the same controller-facing contract — so a
controller can `launch` / `converse` / `wait-for-turn` / `read-turn` / `stop` a
Codex or Pi worker without knowing or caring which harness is inside the pane.

CSD becomes **"Coding-agent Session Driver"** (the `csd` name is retained).

### Non-goals

- No cost/pricing layer (Pi exposes inline cost; we ignore it for now).
- No cross-harness *canonical* transcript schema. Each harness keeps a native,
  per-harness turn parser.
- No change to the controller-facing command surface or its semantics.
- No sandboxing/isolation beyond what CSD does today (workers run on the host).

## Background: how CSD drives Claude today

CSD is a **PTY puppeteer + transcript reader**, not an API client. It runs
`claude` interactively in a tmux pane and reads two files Claude leaves on disk.
Everything rests on **two planes**:

- **Control plane** — `/tmp/claude-workers/<sid>.events.jsonl`, written by CSD's
  own plugin. Claude's lifecycle hooks fire `emit-event`, which appends
  normalized events: `session_start`, `user_prompt_submit`, `pre_tool_use` (tool
  name + input), `stop`, `session_end`. This is the **turn-boundary and liveness
  signal**: `wait-for-turn` blocks on `stop`/`session_end`; `status` reads the
  last event; `send` confirms submission via `user_prompt_submit`.
- **Data plane** — `~/.claude/projects/<encoded-cwd>/<sid>.jsonl`, Claude's own
  transcript. `read-turn` and `converse` parse it with `jq` to reconstruct the
  text/thinking/tool calls of a turn.

The split is the core design move: **wait on the cheap control plane, then read
the schema-bound data plane.** CSD depends on seven harness capabilities
("ports"): (1) a caller-assigned, stable session id; (2) prompt injection into a
live REPL via bracketed paste + Enter; (3) a pluggable lifecycle-hook system; (4)
a turn-end signal; (5) a persisted, parseable transcript at a derivable path; (6)
permission bypass + no human-question blocking; (7) auth via process env.

All seven are currently satisfied by Claude-specific flags, paths, and a schema
smeared across `cmd_launch`, `cmd_send`, `cmd_stop`, `cmd_read_turn`,
`cmd_converse`, `emit-event`, and `_build_worker_env_args`.

## Core idea: keep the spine, swap the adapter

The orchestration **spine** is already harness-agnostic and stays untouched:
tmux lifecycle, the meta/shim/`resolve_session` identity model, `list`, the
wait-then-read pattern, `converse`, consent, the reproduce line.

The **adapter** — the seven ports — moves behind a per-harness **driver**: a
sourced bash file `drivers/<harness>.sh` defining a fixed set of slot functions.
`csd` calls slots; it never names a harness. A worker's `.meta` records its
`harness`, so every later command re-sources the right driver.

*(Alternatives rejected: separate per-harness binaries, or `case $harness` inside
every command. Sourced driver files keep the spine harness-blind, let each driver
be read and tested in isolation, and match how `_lib.sh` is already sourced.)*

### The driver interface (slots)

```
harness_launch_argv   <tmux_name> <cwd> <session_id|""> <plugin_dir>  # argv to exec in tmux
harness_quit_keys                                                      # "/exit" | "/quit" | "C-c"
harness_id_strategy                                                    # "assign" | "derive"
harness_resolve_session_id  <tmux_name> <cwd>                          # derive: find the real sid post-launch
harness_control_plane                                                  # "hooks" | "poll"
harness_transcript_path     <session_id> <cwd>                         # path or glob
harness_parse_turn          <transcript> [--full]                     # native JSONL -> markdown
harness_count_text          <transcript>                              # converse: count assistant text msgs
harness_last_text           <transcript>                              # converse: extract last assistant text
harness_env_args                                                      # the -e VAR=… isolation pins
```

Two slots carry the only real branching; the rest are parameters:

- **`control_plane = hooks | poll`** — `hooks`: load the plugin, the harness
  self-emits events (Claude, Codex). `poll`: spawn a tailer that synthesizes
  events from the transcript (Pi).
- **`id_strategy = assign | derive`** — `assign`: caller picks the id at launch
  (`claude --session-id`). `derive`: the harness mints its own id; CSD launches
  it pointed at a **per-worker config/session directory**, so the worker's
  session is the unique newest file in that dir, and its id is read back from the
  file (Codex, Pi).

## Control plane: one `events.jsonl`, two producers

The load-bearing invariant: **all downstream consumers
(`wait-for-turn`, `status`, `read-events`, `converse`) read only
`events.jsonl` and are completely unchanged.** What varies is *who writes it*:

```
Claude: claude TUI ─hooks─▶ emit-event ─┐
Codex:  codex  TUI ─hooks─▶ emit-event ─┼─▶ events.jsonl ─▶ [unchanged spine]
Pi:     pi     TUI ─writes─▶ session.jsonl │
                                  └─▶ csd poll (tail+map) ─┘   ← the one net-new component
```

For Claude and Codex, the harness's own hook system runs `emit-event`. For Pi,
which has **no hook system**, a small tailer (`csd poll <sid>`) watches the Pi
session file and maps its records into the same event vocabulary.

### Why polling is sufficient — and per-tool, not just per-turn

Empirically verified (see Appendix A). Pi writes **each step as its own record
the instant it happens**, and each record is self-describing:

| Pi session record | synthesized event |
|---|---|
| `{"type":"session", id, cwd}` (line 1) | `session_start` |
| `message` role=`user` | `user_prompt_submit` |
| `message` role=`assistant`, `stopReason:"toolUse"`, content `toolCall{name,arguments}` | `pre_tool_use` (`tool`=name, `tool_input`=arguments) — emitted **before** the tool runs |
| `message` role=`toolResult` `{toolName, isError, content}` | `post_tool_use` (new, optional; Claude/Codex don't emit this today) |
| `message` role=`assistant`, `stopReason:"stop"` (or `error`/other terminal) | `stop` |
| tmux pane gone | `session_end` |

The decisive rule: **`stopReason:"toolUse"` is a tool step (the turn continues);
any other terminal `stopReason` (`stop`, `error`, …) is turn-end.** A multi-tool
turn produces interleaved `toolUse` assistant / `toolResult` records, then one
terminal `stop`.

This gives Pi **full parity** with the hook control plane (per-tool *and*
turn-end, with tool name + input) under the uniform tmux-TUI model — no RPC
needed. Pi's RPC mode would add only token-level streaming deltas, a submit-ack,
and `abort`; none are required for CSD's observe-and-orchestrate loop.

### The poller component (`csd poll`)

- **Lifecycle:** runs as a **second tmux window** inside the worker's session, so
  `tmux kill-session` reaps it for free (no PID bookkeeping) and it is
  inspectable for debugging.
- **Job:** tail the Pi session JSONL, recognize complete lines only (guard
  against half-written and multi-MB lines), map records → events, append to
  `events.jsonl`. Emit `session_end` when the worker pane dies.
- **Robustness:** treat any terminal `stopReason` other than `toolUse` as
  turn-end (handles `error` and future variants); never block on a partial line.

The poller is the **only** net-new logic. `launch` gains one branch:
`hooks`-harness loads the plugin; `poll`-harness opens the poller window.

## Per-harness adapters

| slot | claude | codex | pi |
|---|---|---|---|
| launch argv | `claude --session-id <id> --plugin-dir <p> --settings '{"skipDangerousModePermissionPrompt":true}' --dangerously-skip-permissions --disallowed-tools AskUserQuestion` | `codex --yolo` (interactive); hooks + trust via per-worker `CODEX_HOME` config | `pi --session-dir <wd>/.csd/sessions --model <route>` |
| id strategy | **assign** | **derive** (newest rollout in worker `CODEX_HOME`) | **derive** (newest file in `--session-dir`) |
| quit keys | `/exit` | `/quit` | `C-c` *(verify clean flush)* |
| control plane | hooks | hooks (same `emit-event`, + Codex event-name map) | **poll** |
| turn-end | `stop` event | `Stop` event / `task_complete` | assistant `stopReason:"stop"` |
| transcript | `~/.claude/projects/<enc>/<id>.jsonl` | `$CODEX_HOME/sessions/Y/M/D/rollout-*-<id>.jsonl` | `<session-dir>/<ts>_<id>.jsonl` |
| env isolation | provider-env pin/clear | per-worker `CODEX_HOME` | per-worker `PI_CODING_AGENT_DIR` + `--session-dir` |

### Claude (`drivers/claude.sh`)
Extracts today's behavior **verbatim** — same flags, same `~/.claude/projects`
path formula, same `_build_worker_env_args` provider-env logic (now
`harness_env_args`), same `cmd_read_turn` jq (now `harness_parse_turn`). The
control plane is the existing plugin/hooks. This driver is the regression anchor:
the refactor must change zero Claude behavior.

### Codex (`drivers/codex.sh`)
- **Launch:** interactive `codex` with `--yolo` (skip approvals/sandbox; the
  worker is the trust boundary, as with Claude's `--dangerously-skip-permissions`).
  Codex has no `AskUserQuestion`-style blocker; `--yolo` / approvals-never
  suffices.
- **Control plane = hooks.** Codex's hook system is a near-clone of Claude's:
  command hooks read JSON on stdin (`session_id`, `transcript_path`, `cwd`,
  `hook_event_name`, `tool_name`/`tool_input` on PreToolUse) and the event set
  matches (`SessionStart`, `UserPromptSubmit`, `PreToolUse`, `Stop`,
  `SessionEnd`). The **same `emit-event`** script handles Codex; we add Codex's
  event-name → snake_case mapping. Hooks are registered + pre-trusted via a config
  written into the worker's private `CODEX_HOME` (avoids the interactive
  hook-trust gate; `--enable hooks` if the feature flag is required).
- **Id strategy = derive.** No `--session-id` flag. A per-worker `CODEX_HOME`
  means one session under `<CODEX_HOME>/sessions/**`; `harness_resolve_session_id`
  globs the newest `rollout-*-<uuid>.jsonl` and reads `session_meta.payload.id`.
  (The SessionStart hook payload also carries `session_id` + `transcript_path`;
  either source works. `emit-event` recognizes "this is a worker" by running
  under the worker's private `CODEX_HOME`, then keys `events.jsonl` by the
  `session_id` in its stdin payload.)
- **Transcript:** date-sharded; `harness_transcript_path` globs
  `<CODEX_HOME>/sessions/**/rollout-*-<id>.jsonl`. Parser maps Codex
  `response_item`/`event_msg` records (agent message text, reasoning,
  function_call/output) → markdown.

### Pi (`drivers/pi.sh` + `csd poll`)
- **Launch:** interactive `pi --session-dir <wd>/.csd/sessions --model <route>`.
  Pi requires an explicit model **route** (`<pi-provider>/<model>`, e.g.
  `openai-codex/gpt-5.5` for subscription, `openrouter/<vendor>/<model>` for
  token) — Pi's default provider is `google`, which has no creds here. The route
  is a launch parameter.
- **Control plane = poll.** As above.
- **Id strategy = derive.** `harness_resolve_session_id` reads the newest
  `<session-dir>/<ts>_<uuid>.jsonl` and takes `id` from line 1.
- **Permission bypass:** Pi's interactive tools run unattended (no
  `AskUserQuestion`-style blocker observed); no explicit yolo flag is needed.
- **Auth/env isolation:** per-worker `PI_CODING_AGENT_DIR` + `--session-dir`;
  creds resolve from `~/.pi/agent/auth.json` (OpenRouter key + Codex OAuth blob).

## Identity & naming changes

- **State dir:** `/tmp/claude-workers` → `/tmp/csd-workers`, with a back-compat
  symlink `/tmp/claude-workers → /tmp/csd-workers` so live workers' baked shim
  paths keep resolving across the upgrade.
- **Binary resolution:** `CSD_CLAUDE_BIN` → a per-harness `harness_bin` (e.g.
  `CSD_CLAUDE_BIN`, `CSD_CODEX_BIN`, `CSD_PI_BIN`), each defaulting to the bare
  command name on `PATH`.
- **`launch` gains a harness selector**, e.g. `csd launch --harness codex <name>
  <cwd> [-- harness-args...]` (default `claude` for back-compat). The chosen
  harness is written to `.meta`.
- The `--worker` shim contract, `resolve_session`, and all per-worker subcommands
  are unchanged.

## Transcript handling

Three small native `parse_turn` jq scripts (one per harness), not a shared
normalization layer. Each produces the same markdown shape `read-turn` emits
today (prompt / thinking / tool calls / results, tool results truncated to 5
lines without `--full`). `converse`'s `count_text` / `last_text` helpers likewise
become per-harness, reading each native schema. The wait itself is unchanged — it
keys off `events.jsonl`, which every harness now populates.

## What gets built (sequence)

1. **Refactor to drivers (no behavior change):** extract `drivers/claude.sh`;
   route `cmd_launch`/`cmd_stop`/`cmd_read_turn`/`cmd_converse`/`harness_env_args`
   through slots; generalize `/tmp/claude-workers` → `/tmp/csd-workers` + symlink.
   Existing Claude tests must pass untouched.
2. **Codex driver:** `drivers/codex.sh`; add Codex event-name mapping to
   `emit-event`; per-worker `CODEX_HOME` hook config + trust; derive-id;
   Codex turn parser. New tests.
3. **Pi driver + poller:** `csd poll` tailer (record→event map from Appendix A);
   `drivers/pi.sh`; derive-id; Pi turn parser; poller-as-tmux-window lifecycle.
   New tests.

## Open questions (to verify during implementation; none threaten the design)

- **Pi send + quit:** confirm bracketed-paste + Enter submits in Pi's interactive
  composer (the probe used an initial-prompt positional, not `send`); confirm a
  clean quit key (probe used `C-c` then kill-session).
- **Codex hook trust/feature wiring:** exact `CODEX_HOME` config to pre-trust
  command hooks and whether `--enable hooks` / `-c features.hooks=true` is needed
  on this version.
- **Pi `stopReason` variants** beyond `stop` / `toolUse` / `error`.
- **Codex submit-confirmation:** Codex emits `UserPromptSubmit`; confirm the
  send-retry loop keys off it the same way Claude does.

## Appendix A — Pi flush-timing probe (evidence)

One interactive Pi session in tmux, forced a `bash` tool call with a known 6s
delay, polled the session file every 0.4s. Observed arrival timeline:

```
T+2.5  session header
T+2.5  message role=user                                    (prompt)
T+2.5  message role=assistant stopReason=toolUse  toolCall  (bash: sleep 6 && echo …)
T+8.8  message role=toolResult  isError=false               (after the 6s sleep)
T+9.7  message role=assistant stopReason=stop     text      (final reply)
```

The tool-call record lands **~6s before** its result — Pi flushes each step
incrementally, so the poller sees a tool *before it runs*. The `toolCall` record
carries `{name, arguments}` (full tool input) and the `toolResult` carries
`{toolName, isError, content}`. Record schema: `{type, id, parentId, timestamp,
message:{role, content:[{type}], stopReason, usage?}}`; roles `user` /
`assistant` / `toolResult`; content types `text` / `toolCall`. This is the
empirical basis for the record→event map above.
