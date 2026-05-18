---
name: driving-claude-code-sessions
description: Use when acting as a project manager that delegates tasks to other Claude Code sessions - launch workers, assign them work, monitor progress, review their tool calls, and collect results
---

# Driving Claude Code Sessions

## Overview

You can launch other Claude Code sessions as "workers" in tmux, send them prompts, wait for them to finish, read their output, and hand them off to a human. Workers run with `--dangerously-skip-permissions`, so they execute tool calls without prompting. A plugin (claude-session-driver) emits lifecycle events to a JSONL file so the controller can observe what the worker is doing.

All operations go through a single CLI: `csd`. After launching a worker, the controller receives a **shim path** at `/tmp/claude-workers/bin/<tmux-name>` that bakes in the worker handle. Every per-worker operation goes through that path — no environment variables to remember, no absolute skill path to prepend.

The shim path is deterministic: if you pick a memorable tmux name at launch, you can reconstruct `/tmp/claude-workers/bin/<tmux-name>` whenever you need it. For agents driving via tool calls, that's the right model — shell state doesn't persist between calls, so a `SHIM=...; $SHIM cmd` pattern just adds noise. The examples below use the bare path.

## Prerequisites

- **tmux**
- **jq**
- **claude** CLI

## Setup

The CLI lives at `<skill>/scripts/csd`. Three top-level subcommands need the skill path:

- `csd launch <tmux-name> <cwd> [-- claude-args...]` — bootstrap a worker
- `csd list [--all]` — enumerate workers
- `csd grant-consent` — one-time consent for `--dangerously-skip-permissions`

Once a worker is launched, run subsequent commands against `/tmp/claude-workers/bin/<tmux-name>`:

```bash
SKILL=/abs/path/to/skill/scripts
$SKILL/csd grant-consent                          # one-time per machine
$SKILL/csd launch my-task /path/to/project        # stdout: /tmp/claude-workers/bin/my-task
/tmp/claude-workers/bin/my-task status            # use the shim directly
```

Pick a memorable tmux name at launch; the shim path is then deterministic. (You *can* capture it into a shell variable in an interactive shell, but for agent-driven workflows the bare path is simpler — there's no shell state to lose between calls.)

## Workflow

In examples below, `$SKILL` is the absolute path to `skills/driving-claude-code-sessions/scripts`. `WORKER` is the bare shim path (e.g. `/tmp/claude-workers/bin/my-task`) — substitute the deterministic path for your worker.

### 1. Launch

```bash
$SKILL/csd launch my-task /path/to/project
# stdout: /tmp/claude-workers/bin/my-task
# stderr: Worker launched. tmux/session_id/cwd/events/reproduce
```

`csd launch`:
- Writes a meta file and a 3-line shim at `/tmp/claude-workers/bin/my-task`
- Starts tmux + claude with the plugin loaded
- Waits up to 30s for `session_start`
- Prints the shim path on stdout (one line)
- Prints a "Worker launched" panel on stderr — the `reproduce:` line is the exact command to relaunch with the same args

Pass claude CLI args after a `--` separator:
```bash
$SKILL/csd launch my-task /path/to/project -- --model sonnet
```

### 2. Converse (the typical case)

```bash
/tmp/claude-workers/bin/my-task converse "Refactor the auth module" 300
```

`converse` sends the prompt, waits for the worker to finish, and prints the final assistant text on stdout. For tool-heavy turns where the bare text strips the interesting part, use `--with-turn` to get the full markdown:

```bash
/tmp/claude-workers/bin/my-task converse --with-turn "Run the failing tests" 600
```

Multi-turn just works — the wait tracks turn boundaries automatically:

```bash
/tmp/claude-workers/bin/my-task converse "Write tests for the auth module" 300
/tmp/claude-workers/bin/my-task converse "Add edge cases for expired tokens" 300
```

### 3. Lower-level control

If you need to drive the worker more directly:

```bash
/tmp/claude-workers/bin/my-task send "Refactor the auth module"     # send without waiting
/tmp/claude-workers/bin/my-task wait-for-turn 300                   # block until stop or session_end
/tmp/claude-workers/bin/my-task status                              # idle | working | terminated | gone | unknown
/tmp/claude-workers/bin/my-task read-turn                           # last turn as markdown (tool results truncated to 5 lines)
/tmp/claude-workers/bin/my-task read-turn --full                    # last turn with complete tool results
```

### 4. Watching what the worker does

Every tool call emits a `pre_tool_use` event with the tool name and input. Tail the event stream to watch in real time:

```bash
/tmp/claude-workers/bin/my-task read-events --follow &
MONITOR_PID=$!
# ... do other work ...
kill $MONITOR_PID
```

Or pull events after the fact:

```bash
/tmp/claude-workers/bin/my-task read-events                       # all events
/tmp/claude-workers/bin/my-task read-events --last 5
/tmp/claude-workers/bin/my-task read-events --type pre_tool_use
```

`--type` accepts one of: `session_start`, `user_prompt_submit`, `pre_tool_use`, `stop`, `session_end`. Unknown event names fail fast.

If you see something you don't want, stop the worker:

```bash
/tmp/claude-workers/bin/my-task stop
```

### 5. Stop and clean up

```bash
/tmp/claude-workers/bin/my-task stop
```

Sends `/exit`, waits up to 10s for `session_end`, kills the tmux session if still running, and removes the meta, events, **and shim** files.

`stop` is destructive: the worker is gone and the shim path stops working. If you wanted the worker around for follow-up turns or a parallel workflow, don't call `stop` until you're done with it. To resume work under the same name, relaunch — `csd launch my-task /path/to/project` again — and you'll get a fresh worker at the same shim path.

After `stop`, the shim no longer exists, so invoking it again surfaces a shell error along the lines of `no such file or directory: /tmp/claude-workers/bin/my-task` (the exact wording depends on your shell). That's expected; the worker is gone.

### 6. Hand off to a human

```bash
/tmp/claude-workers/bin/my-task handoff
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
csd launch <tmux-name> <cwd> [-- claude-args...]
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

`<shim>` is `/tmp/claude-workers/bin/<tmux-name>`. Run `csd help` for the same surface.

## Common Patterns

### Fan-Out: Multiple Workers in Parallel

```bash
$SKILL/csd launch worker-api ~/proj
$SKILL/csd launch worker-ui ~/proj

/tmp/claude-workers/bin/worker-api send "Add pagination to /users"
/tmp/claude-workers/bin/worker-ui send "Add a loading spinner to the user list"

/tmp/claude-workers/bin/worker-api wait-for-turn 600
/tmp/claude-workers/bin/worker-ui wait-for-turn 600

/tmp/claude-workers/bin/worker-api stop
/tmp/claude-workers/bin/worker-ui stop
```

### Pipeline: Worker A produces, Worker B consumes

```bash
$SKILL/csd launch spec ~/proj
/tmp/claude-workers/bin/spec converse "Write an OpenAPI spec for /users to /tmp/api.yaml" 300
/tmp/claude-workers/bin/spec stop

$SKILL/csd launch impl ~/proj
/tmp/claude-workers/bin/impl converse "Implement the endpoint defined in /tmp/api.yaml" 600
/tmp/claude-workers/bin/impl stop
```

## Edge Cases

### Worker crashes mid-turn

`wait-for-turn` matches `stop` OR `session_end`, so it returns when the worker dies. Call `status` afterward: if it's `gone`, the worker crashed.

### Lost the shim path

If you know the tmux name, the path is `/tmp/claude-workers/bin/<tmux-name>`. If you don't, `csd list` enumerates everything; `csd list <pattern>` filters by tmux-name substring.

### Long prompts

`send` uses bracketed-paste, which handles multi-line and special characters. For prompts in the tens-of-KB range, write to a file and tell the worker to read it:

```bash
echo "Long instructions..." > /tmp/instructions.txt
/tmp/claude-workers/bin/my-task send "Read /tmp/instructions.txt and follow it"
```

## Important Notes

- **One controller per worker.** Two controllers driving the same tmux session will collide.
- **Workers don't share state with the controller** except via files on disk and the event stream.
- **Shim paths bake in absolute skill paths.** A plugin reinstall at a new location breaks live workers; relaunch them.
