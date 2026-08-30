---
name: driving-claude-code-sessions
description: Use when acting as a project manager that delegates tasks to other coding-agent sessions (Claude Code, Codex, or Pi) - launch workers, assign them work, monitor progress, review their tool calls, and collect results
---

# Driving Coding-Agent Sessions

## Overview

You can launch coding-agent sessions — Claude Code, Codex, or Pi — as "workers" in tmux, send them prompts, wait for them to finish, read their output, and hand them off to a human. Workers run with permissions bypassed, so they execute tool calls without prompting. Each worker emits lifecycle events to a JSONL file so the controller can observe what it's doing — Claude and Codex through their hook systems, Pi through a native extension `csd` loads into it.

All operations go through a single CLI: `csd`. After launching a worker, the controller receives a **shim path** at `/tmp/csd-workers/bin/<tmux-name>` that bakes in the worker handle. Every per-worker operation goes through that path — no positional state to thread between calls, no absolute skill path to prepend. A small set of environment variables tune behavior; see [Environment variables](#environment-variables) at the bottom.

(The worker dir moved from `/tmp/claude-workers` to `/tmp/csd-workers`; when the default path is in use, `csd` creates a back-compat symlink `/tmp/claude-workers → /tmp/csd-workers`, so old paths and muscle memory still resolve.)

The shim path is deterministic: if you pick a memorable tmux name at launch, you can reconstruct `/tmp/csd-workers/bin/<tmux-name>` whenever you need it. For agents driving via tool calls, that's the right model — shell state doesn't persist between calls, so a `SHIM=...; $SHIM cmd` pattern just adds noise. The examples below use the bare path.

## Harnesses

Pick a harness with `--harness` at launch (default `claude`):

```bash
$SKILL/csd launch --harness codex my-task /path/to/project
$SKILL/csd launch --harness pi    my-task /path/to/project
```

The controller-facing command surface is **identical across all three harnesses** — `launch`, `send`, `converse`, `wait-for-turn`, `read-turn`, `read-events`, `status`, `stop`, and `handoff` behave the same regardless of harness. A few things differ:

- **Auth.** Each harness authenticates from its own home — Claude `~/.claude`, Codex `~/.codex`, Pi `~/.pi/agent`. `csd` stages that login into the worker at launch, so to rotate credentials, relaunch.
- **`adopt` is Claude-only.** Claude takes a caller-assigned session id, so a session can be resumed by id (`claude --resume`). Codex and Pi mint their own ids on the first prompt and offer no resume-by-id — relaunch them instead.
- **Codex isn't queryable until its first prompt.** Codex mints its session id only when you send the first prompt, so between `launch` and the first `send`/`converse` a codex worker's `status`, `session-id`, and `wait-for-turn` return `no worker known` — it *is* running, it just hasn't registered yet. `converse` handles this internally, so the typical launch→converse path is fine; only the lower-level commands see the gap. (Claude takes its id at launch and Pi registers at launch, so both are queryable immediately.)

## Prerequisites

- **tmux**
- a harness CLI — at least the one you launch: **claude** (default), **codex**, or **pi**

(No `jq` and no bash hooks: `csd` is a TypeScript/node tool and its hooks are node programs. `node` is required, but it's already present wherever Claude Code runs.)

## Setup

The CLI lives at `<skill>/scripts/csd`. Top-level subcommands need the skill path:

- `csd launch [--harness <claude|codex|pi>] <tmux-name> <cwd> [-- harness-args...]` — bootstrap a worker (harness defaults to `claude`)
- `csd adopt <tmux-name> <cwd> <session-id> [-- claude-args...]` — re-adopt an existing Claude session as a worker (claude-only; see [Recovering workers](#recovering-workers-after-a-reboot))
- `csd list [--all]` — enumerate workers
- `csd grant-consent` — one-time consent for running workers with permissions bypassed
- `csd grant-workspace-trust <cwd>` — interactively allow CSD to accept Claude's workspace trust prompt for one canonical directory

Once a worker is launched, run subsequent commands against `/tmp/csd-workers/bin/<tmux-name>`:

```bash
SKILL=/abs/path/to/skill/scripts
$SKILL/csd grant-consent                          # one-time per machine
$SKILL/csd launch my-task /path/to/project        # stdout: /tmp/csd-workers/bin/my-task
/tmp/csd-workers/bin/my-task status               # use the shim directly
```

Pick a memorable tmux name at launch; the shim path is then deterministic. (You *can* capture it into a shell variable in an interactive shell, but for agent-driven workflows the bare path is simpler — there's no shell state to lose between calls.)

## Workflow

In examples below, `$SKILL` is the absolute path to `skills/driving-claude-code-sessions/scripts`. `WORKER` is the bare shim path (e.g. `/tmp/csd-workers/bin/my-task`) — substitute the deterministic path for your worker.

### 1. Launch

```bash
$SKILL/csd launch my-task /path/to/project
# stdout: /tmp/csd-workers/bin/my-task
# stderr: Worker launched. tmux/session_id/cwd/events/reproduce
```

`csd launch`:
- Writes a 3-line shim at `/tmp/csd-workers/bin/my-task`
- Starts tmux and the harness in it
- Blocks until the worker is ready — Claude (which takes a caller-assigned session id) waits for its `session_start` event; Codex and Pi mint their own ids on the first prompt, so launch settles their TUI and the worker's meta self-registers when it fires its first event
- Prints the shim path on stdout (one line)
- Prints a "Worker launched" panel on stderr — the `reproduce:` line is the exact command to relaunch with the same args

Pass harness CLI args after a `--` separator, or pick a non-default harness with `--harness`:
```bash
$SKILL/csd launch my-task /path/to/project -- --model sonnet
$SKILL/csd launch --harness codex my-task /path/to/project
```

### 2. Converse (the typical case)

```bash
/tmp/csd-workers/bin/my-task converse "Refactor the auth module" 300
```

`converse` sends the prompt, waits for the worker to finish, and prints the final assistant text on stdout. A successful reply exits 0. A proven Claude API failure exits 3 with structured evidence on stderr; an expired wait without terminal evidence exits 124. Both failure outcomes leave the worker alive for inspection or another prompt. For tool-heavy turns where the bare text strips the interesting part, use `--with-turn` to get the full markdown:

```bash
/tmp/csd-workers/bin/my-task converse --with-turn "Run the failing tests" 600
```

Multi-turn just works — the wait tracks turn boundaries automatically:

```bash
/tmp/csd-workers/bin/my-task converse "Write tests for the auth module" 300
/tmp/csd-workers/bin/my-task converse "Add edge cases for expired tokens" 300
```

### 3. Lower-level control

If you need to drive the worker more directly:

```bash
/tmp/csd-workers/bin/my-task send "Refactor the auth module"     # send without waiting
/tmp/csd-workers/bin/my-task wait-for-turn 300                   # block until stop, stop_failure, or session_end
/tmp/csd-workers/bin/my-task status                              # idle | working | terminated | gone | unknown
/tmp/csd-workers/bin/my-task read-turn                           # last turn as markdown (tool results truncated to 5 lines)
/tmp/csd-workers/bin/my-task read-turn --full                    # last turn with complete tool results
```

### 4. Watching what the worker does

Every tool call emits a `pre_tool_use` event with the tool name and input. Tail the event stream to watch in real time:

```bash
/tmp/csd-workers/bin/my-task read-events --follow &
MONITOR_PID=$!
# ... do other work ...
kill $MONITOR_PID
```

Or pull events after the fact:

```bash
/tmp/csd-workers/bin/my-task read-events                       # all events
/tmp/csd-workers/bin/my-task read-events --last 5
/tmp/csd-workers/bin/my-task read-events --type pre_tool_use
```

`--type` accepts one of: `session_start`, `user_prompt_submit`, `pre_tool_use`, `post_tool_use`, `stop`, `stop_failure`, `session_end`. Unknown event names fail fast. (Claude workers emit `pre_tool_use` but not `post_tool_use`; Codex and Pi emit both.)

If you see something you don't want, stop the worker:

```bash
/tmp/csd-workers/bin/my-task stop
```

### 5. Stop and clean up

```bash
/tmp/csd-workers/bin/my-task stop
```

Sends `/exit`, waits up to 10s for `session_end`, kills the tmux session if still running, and removes the meta, events, **and shim** files.

`stop` is destructive: the worker is gone and the shim path stops working. If you wanted the worker around for follow-up turns or a parallel workflow, don't call `stop` until you're done with it. To resume work under the same name, relaunch — `csd launch my-task /path/to/project` again — and you'll get a fresh worker at the same shim path.

After `stop`, the shim no longer exists, so invoking it again surfaces a shell error along the lines of `no such file or directory: /tmp/csd-workers/bin/my-task` (the exact wording depends on your shell). That's expected; the worker is gone.

### 6. Hand off to a human

```bash
/tmp/csd-workers/bin/my-task handoff
```

Prints attach instructions for a human to take over the tmux session.

### Finding workers

```bash
$SKILL/csd list                      # live workers (idle/working/terminated)
$SKILL/csd list --all                # include 'gone' workers (tmux already exited)
$SKILL/csd list api                  # substring filter on tmux name
$SKILL/csd prune                     # remove dead workers + orphaned sidecars/shims
```

## Reference

```
csd launch [--harness <claude|codex|pi>] <tmux-name> <cwd> [-- harness-args...]
csd adopt <tmux-name> <cwd> <session-id> [-- claude-args...]   # claude-only
csd list [--all] [<pattern>]
csd prune                          # remove dead/orphaned worker state
csd grant-consent
csd grant-workspace-trust <cwd>       # interactive, Claude workspace trust only

<shim> converse [--with-turn] <prompt> [timeout=120]
<shim> send <prompt>
<shim> wait-for-turn [timeout=60] [--after-line N]
<shim> status
<shim> read-events [--last N] [--type T] [--follow]   # --last caps the --follow backlog
<shim> read-turn [--full]
<shim> stop
<shim> handoff
<shim> session-id
<shim> events-file
```

`<shim>` is `/tmp/csd-workers/bin/<tmux-name>`. Run `csd help` for the same surface.

Exit codes used for supervision:

- `0`: command succeeded; a waiting command observed normal completion.
- `1`: operational error.
- `2`: CLI usage error.
- `3`: the current turn ended with proven API-error evidence.
- `4`: reserved for a future interruption contract.
- `124`: the wait budget expired while the turn remained open or indeterminate.

## Common Patterns

### Fan-Out: Multiple Workers in Parallel

```bash
$SKILL/csd launch worker-api ~/proj
$SKILL/csd launch worker-ui ~/proj

/tmp/csd-workers/bin/worker-api send "Add pagination to /users"
/tmp/csd-workers/bin/worker-ui send "Add a loading spinner to the user list"

/tmp/csd-workers/bin/worker-api wait-for-turn 600
/tmp/csd-workers/bin/worker-ui wait-for-turn 600

/tmp/csd-workers/bin/worker-api stop
/tmp/csd-workers/bin/worker-ui stop
```

### Pipeline: Worker A produces, Worker B consumes

```bash
$SKILL/csd launch spec ~/proj
/tmp/csd-workers/bin/spec converse "Write an OpenAPI spec for /users to /tmp/api.yaml" 300
/tmp/csd-workers/bin/spec stop

$SKILL/csd launch impl ~/proj
/tmp/csd-workers/bin/impl converse "Implement the endpoint defined in /tmp/api.yaml" 600
/tmp/csd-workers/bin/impl stop
```

Don't trust worker B's summary of what it did — check the produced file. A worker can report success while having written the wrong thing (see *Important Notes*).

## Edge Cases

### Worker crashes mid-turn

`wait-for-turn` matches `stop`, `stop_failure`, OR `session_end`, so it returns when the worker dies or Claude reports a terminal API failure. Call `status` afterward: if it's `gone`, the worker crashed.

### Claude workspace trust blocks launch or adopt

If `launch` or `adopt` reports that the canonical workspace has no grant, run
the exact `grant-workspace-trust` command it prints in an interactive terminal.
Review the normalized path and type that complete path exactly; do not pipe
`yes` or automate the confirmation. Relaunch after the grant succeeds.

CSD stores its own hashed, owner-only per-workspace grant and does not directly
edit Claude's `~/.claude.json`; Claude controls its own persistence after the
prompt is accepted. The grant lets CSD press Enter only on Claude's workspace
trust dialog. It does not authorize separate security decisions such as
external `CLAUDE.md` imports. Claude intentionally asks again on every launch
from the home directory; granting the canonical home path lets CSD confirm that
workspace prompt each time without weakening other prompts.

### Claude API failures

When Claude Code emits `StopFailure`, `wait-for-turn` and `converse` return exit
3 and write the worker name, session ID, error type/details, rendered error,
and diagnostic paths to stderr. Do not treat stderr as an assistant response and
do not retry automatically; inspect the provider error first. The worker maps
back to the existing `idle` status and remains reusable.

If a Claude `converse` wait expires without the hook, CSD performs one bounded
transcript-tail check. It revalidates the pre-send UUID and byte-offset snapshot,
then reads at most 1 MiB after the anchor. It returns 3 only when a non-sidechain
assistant is structurally marked `isApiErrorMessage: true` and its `parentUuid`
ancestry reaches the anchor. Missing/mismatched anchors, transcript replacement
or rewrite, oversized/malformed tails, orphan/sidechain errors, unknown
UUID-bearing chain types, later substantive assistant content, or no marked
terminal record remains exit 124. This fallback proves API failure only; it
never proves normal completion.

### After a `wait-for-turn` timeout, reuse its cursor

Exit 124 prints `retry_after_line: N` and a retry hint. If the worker is still
active, rerun the same shim with that baseline:

```bash
/tmp/csd-workers/bin/my-task wait-for-turn --after-line N
```

Do not use a bare retry: it baselines at the event file's current end and can
skip a terminal event that arrived after the first timeout.

### After a `converse` timeout, check `status` before `wait-for-turn`

A bare `wait-for-turn` baselines at the *current* end of the events file and waits for the **next** turn-end. If `converse` exits 124, the worker remains alive and may finish during the gap — the terminal event can land before a follow-up wait begins. `converse` prints `retry_after_line: N` and the complete worker-shim retry command. Inspect the event/transcript paths and call `status` first: `idle` means the turn already ended (`read-turn` to inspect it); `working` means it is still open or the terminal hook was unavailable. Then use the printed retry command when the turn is still working or when you need to consume a terminal event that landed after timeout. Do not use a bare wait, and do not stop the worker merely because the caller's wait expired.

### Recovering workers after a reboot

Worker runtime state (the `meta`/`events`/`shim` files under `/tmp/csd-workers`) lives in `/tmp`, which macOS clears on reboot — and the tmux panes die with it. But the *conversations* survive: Claude Code persists each session transcript at `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`. `csd adopt` brings one back as a live, driveable worker (this is **claude-only** — Codex and Pi mint their own session ids and offer no resume-by-id, so relaunch those instead):

```bash
$SKILL/csd adopt my-task /path/to/project <session-id>
# stdout: /tmp/csd-workers/bin/my-task   (same shim contract as launch)
```

**This is claude-only — codex/pi conversations do NOT survive `stop`.** Codex and Pi run under a staged per-worker home at `/tmp/csd-workers/homes/<name>/` (config, auth, and the rollout/session transcript), *not* your real `~/.codex` / `~/.pi`. `stop` removes that home, so the transcript is gone and there is no recovery path — relaunch starts a fresh session. Only claude persists its transcript outside the worker dir (in `~/.claude/projects`), which is why only claude is adoptable.

`adopt` pre-writes the meta keyed by `<session-id>`, starts `claude --resume <session-id>` (which preserves the id, so the worker emits events normally), and writes the shim — so the resumed conversation is fully driveable (`converse`/`status`/`read-turn`/…), with all prior context intact. If a tmux session of that name already exists (e.g. restored by [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect) / tmux-continuum), `adopt` respawns its pane *in place*, preserving the restored layout; otherwise it opens a new one.

Find a worker's `<session-id>` from its working directory: the newest `*.jsonl` in `~/.claude/projects/<cwd with every / . _ replaced by ->`. For bulk recovery (e.g. pairing with tmux-continuum's `@continuum-boot`), `examples/recover-workers.sh` reads a tmux-resurrect snapshot, derives each id, and calls `adopt` per worker — run it with `--dry-run` first. Note: workers are restored as resumed sessions, not their original tool/MCP state; re-pass any launch args (e.g. `-- --model …`) you depended on.

### Lost the shim path

If you know the tmux name, the path is `/tmp/csd-workers/bin/<tmux-name>`. If you don't, `csd list` enumerates everything; `csd list <pattern>` filters by tmux-name substring.

### Long prompts

`send` uses bracketed-paste, which handles multi-line and special characters. For prompts in the tens-of-KB range, write to a file and tell the worker to read it:

```bash
echo "Long instructions..." > /tmp/instructions.txt
/tmp/csd-workers/bin/my-task send "Read /tmp/instructions.txt and follow it"
```

## Important Notes

- **One controller per worker.** Two controllers driving the same tmux session will collide.
- **Milestone A correlation boundary.** Terminal outcomes cover one controller waiting on its own turn with no concurrent handoff prompt. CSD does not yet assign turn IDs, claim turns, correlate queued prompts, classify interruption, or reconcile multiple controllers.
- **Workers don't share state with the controller** except via files on disk and the event stream.
- **Shim paths bake in absolute skill paths.** A plugin reinstall at a new location breaks live workers; relaunch them.
- **csd is a transparent relay, not a validator.** `converse`/`read-turn` return whatever the worker says — verbatim, including when the worker is confidently wrong. For correctness-critical handoffs, verify the produced **artifact on disk**, not the worker's prose self-report.

## Environment variables

The `csd` CLI honors a small set of env vars. All are optional.

| Variable | Purpose |
|---|---|
| `CSD_CLAUDE_BIN` / `CSD_CODEX_BIN` / `CSD_PI_BIN` | Path to each harness binary. Default to `claude` / `codex` / `pi` (resolved via `PATH`). Set when a binary is not on `PATH` or you want to pin a specific version. |
| `CSD_CODEX_MODEL` / `CSD_PI_MODEL` | Optional model override for codex / pi workers. Unset = the harness default (codex: `gpt-5.5`; pi: its configured default). |
| `CSD_CONVERSE_DIAG_FILE` | When set, `csd converse` writes a post-mortem diagnostic on timeout — `ps` tree, `tmux capture-pane`, last 30 lines of the worker's session JSONL, last 20 lines of the csd events JSONL — to this path, then emits a `csd-diagnostic: <path>` pointer to stderr. The file is overwritten on each timeout. Unset = no diagnostic file. Useful when wrapping csd in a harness that can ship the file off-box before the worker is reaped. |
| `CSD_WORKER_DIR` | Override the worker dir (default `/tmp/csd-workers`). The back-compat `/tmp/claude-workers` symlink is only created when the default is in use. |
| `CSD_SUBMIT_TIMEOUT` / `CSD_SUBMIT_RETRY_INTERVAL` | `send`: seconds to wait for the worker to confirm a pasted prompt (default `10`) and seconds between retry-Enter resends (default `2`). Raise the timeout if a slow tmux session drops the paste. |
| `CSD_REGISTER_TIMEOUT` | Seconds the FIRST `send`/`converse` to a derive worker (codex/pi) waits for it to self-register its session id (default `15`). |
| `HOME` | Used to locate `~/.claude/projects/<encoded-cwd>/<sid>.jsonl` (claude) and the one-time consent file (`~/.claude/.claude-session-driver-consent`). |

`csd help` shows the same surface.
