---
name: driving-claude-code-sessions
description: Use when acting as a project manager that delegates tasks to other coding-agent sessions (Claude Code, Codex, or Pi) - launch workers, assign them work, monitor progress, review their tool calls, and collect results
---

# Driving Coding-Agent Sessions

## Overview

You can launch coding-agent sessions — Claude Code, Codex, or Pi — as "workers" in tmux, send them prompts, wait for them to finish, read their output, and hand them off to a human. Workers run with permissions bypassed, so they execute tool calls without prompting. Each worker emits lifecycle events to a JSONL file so the controller can observe what it's doing — Claude and Codex through their hook systems, Pi through a tailer `csd` runs alongside it.

All operations go through a single CLI: `csd`. After launching a worker, the controller receives a **shim path** at `/tmp/csd-workers/bin/<tmux-name>` that bakes in the worker handle. Every per-worker operation goes through that path — no positional state to thread between calls, no absolute skill path to prepend. A small set of environment variables tune behavior; see [Environment variables](#environment-variables) at the bottom.

The shim path is deterministic: if you pick a memorable tmux name at launch, you can reconstruct `/tmp/csd-workers/bin/<tmux-name>` whenever you need it. For agents driving via tool calls, that's the right model — shell state doesn't persist between calls, so a `SHIM=...; $SHIM cmd` pattern just adds noise. The examples below use the bare path.

## Harnesses

Pick a harness with `--harness` at launch (default `claude`):

```bash
$SKILL/csd launch --harness codex my-task /path/to/project
$SKILL/csd launch --harness pi    my-task /path/to/project
```

Everything after launch is identical across harnesses — `converse`, `read-turn`, `read-events`, `status`, `stop`, and `handoff` all behave the same. Two things differ:

- **Auth.** Each harness authenticates from its own home — Claude `~/.claude`, Codex `~/.codex`, Pi `~/.pi/agent`. `csd` copies that login into the worker at launch, so to rotate credentials, relaunch.
- **`adopt` is Claude-only.** Claude takes a caller-assigned session id, so a session can be resumed by id. Codex and Pi mint their own ids on the first prompt and offer no resume-by-id — relaunch them instead.

## Prerequisites

- **tmux**
- **jq**
- a harness CLI — **claude** (default), **codex**, or **pi**

## Setup

The CLI lives at `<skill>/scripts/csd`. Three top-level subcommands need the skill path:

- `csd launch [--harness <name>] <tmux-name> <cwd> [-- harness-args...]` — bootstrap a worker (harness defaults to `claude`)
- `csd adopt <tmux-name> <cwd> <session-id> [-- claude-args...]` — re-adopt an existing Claude session as a worker (see [Recovering workers](#recovering-workers-after-a-reboot))
- `csd list [--all]` — enumerate workers
- `csd grant-consent` — one-time consent to run workers with permissions bypassed

Once a worker is launched, run subsequent commands against `/tmp/csd-workers/bin/<tmux-name>`:

```bash
SKILL=/abs/path/to/skill/scripts
$SKILL/csd grant-consent                          # one-time per machine
$SKILL/csd launch my-task /path/to/project        # stdout: /tmp/csd-workers/bin/my-task
/tmp/csd-workers/bin/my-task status            # use the shim directly
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
- Blocks until the worker is ready — Claude waits for `session_start`; Codex and Pi settle, then reconfirm on the first send
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

`converse` sends the prompt, waits for the worker to finish, and prints the final assistant text on stdout. For tool-heavy turns where the bare text strips the interesting part, use `--with-turn` to get the full markdown:

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
/tmp/csd-workers/bin/my-task wait-for-turn 300                   # block until stop or session_end
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

`--type` accepts one of: `session_start`, `user_prompt_submit`, `pre_tool_use`, `post_tool_use`, `stop`, `session_end`. Unknown event names fail fast. (`post_tool_use` comes from Codex and Pi workers, not Claude.)

If you see something you don't want, stop the worker:

```bash
/tmp/csd-workers/bin/my-task stop
```

### 5. Stop and clean up

```bash
/tmp/csd-workers/bin/my-task stop
```

Sends the worker's quit command, waits up to 10s for `session_end`, kills the tmux session if still running, and removes the meta, events, **and shim** files.

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
```

## Reference

```
csd launch [--harness <name>] <tmux-name> <cwd> [-- harness-args...]
csd adopt <tmux-name> <cwd> <session-id> [-- claude-args...]    # claude only
csd list [--all] [<pattern>]
csd grant-consent

<shim> converse [--with-turn] <prompt> [timeout=120]
<shim> send <prompt>
<shim> wait-for-turn [timeout=60]
<shim> status
<shim> read-events [--last N] [--type T] [--follow]
<shim> read-turn [--full]
<shim> stop
<shim> handoff
<shim> session-id
<shim> events-file
```

`<shim>` is `/tmp/csd-workers/bin/<tmux-name>`. Run `csd help` for the same surface.

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

## Edge Cases

### Worker crashes mid-turn

`wait-for-turn` matches `stop` OR `session_end`, so it returns when the worker dies. Call `status` afterward: if it's `gone`, the worker crashed.

### Recovering workers after a reboot

Worker runtime state (the `meta`/`events`/`shim` files under `/tmp/csd-workers`) lives in `/tmp`, which macOS clears on reboot — and the tmux panes die with it. But the *conversations* survive: Claude Code persists each session transcript at `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`. `csd adopt` brings one back as a live, driveable worker:

```bash
$SKILL/csd adopt my-task /path/to/project <session-id>
# stdout: /tmp/csd-workers/bin/my-task   (same shim contract as launch)
```

`adopt` pre-writes the meta keyed by `<session-id>`, starts `claude --resume <session-id>` (which preserves the id, so the worker emits events normally), and writes the shim — so the resumed conversation is fully driveable (`converse`/`status`/`read-turn`/…), with all prior context intact. If a tmux session of that name already exists (e.g. restored by [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect) / tmux-continuum), `adopt` respawns its pane *in place*, preserving the restored layout; otherwise it opens a new one. Because `adopt` resumes by session id, it is Claude-only — Codex and Pi mint their own ids and offer no resume-by-id, so relaunch those instead.

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
- **Workers don't share state with the controller** except via files on disk and the event stream.
- **Shim paths bake in absolute skill paths.** A plugin reinstall at a new location breaks live workers; relaunch them.
- **Worker state lives in `/tmp/csd-workers`.** `/tmp/claude-workers` is kept as a best-effort back-compat symlink for shims baked by older versions; relaunch live workers after upgrading.

## Environment variables

The `csd` CLI honors a small set of env vars. All are optional.

| Variable | Purpose |
|---|---|
| `CSD_CLAUDE_BIN` | Path to the `claude` binary. Defaults to `claude` (resolved via `PATH`). Set when claude is not on `PATH` or you want to pin a specific version. |
| `CSD_CODEX_BIN`, `CSD_PI_BIN` | The same, for the `codex` and `pi` binaries when driving those harnesses. |
| `CSD_CODEX_MODEL`, `CSD_PI_MODEL` | Model to launch a Codex or Pi worker with. Defaults: `gpt-5.5` (codex), `openai-codex/gpt-5.5` (pi). |
| `CSD_WORKER_DIR` | Worker state directory. Defaults to `/tmp/csd-workers`. |
| `CSD_CONVERSE_DIAG_FILE` | When set, `csd converse` writes a post-mortem diagnostic on timeout — `ps` tree, `tmux capture-pane`, last 30 lines of the claude session JSONL, last 20 lines of the csd events JSONL — to this path, then emits a `csd-diagnostic: <path>` pointer to stderr. The file is overwritten on each timeout. Unset = no diagnostic file. Useful when wrapping csd in a harness that can ship the file off-box before the worker is reaped. |
| `HOME` | Locates the Claude transcript (`~/.claude/projects/<encoded-cwd>/<sid>.jsonl`), the consent file (`~/.claude/.claude-session-driver-consent`), and the per-harness auth staged at launch (`~/.codex`, `~/.pi/agent`). Codex and Pi record their own transcript path in the worker meta. |

The same list is shown by `csd help`.
