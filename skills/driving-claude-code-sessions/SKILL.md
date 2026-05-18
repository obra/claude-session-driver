---
name: driving-claude-code-sessions
description: Use when acting as a project manager that delegates tasks to other Claude Code sessions - launch workers, assign them work, monitor progress, review their tool calls, and collect results
---

# Driving Claude Code Sessions

## Overview

You can launch other Claude Code sessions as "workers" in tmux, send them prompts, wait for them to finish, read their output, and hand them off to a human. Workers run with `--dangerously-skip-permissions`, so they execute tool calls without prompting. A plugin (claude-session-driver) emits lifecycle events to a JSONL file so the controller can observe what the worker is doing.

All operations go through a single CLI: `csd`. After launching a worker, the controller receives a **shim path** at `/tmp/claude-workers/bin/<tmux-name>` that bakes in the worker handle. Every per-worker operation goes through that path — no environment variables to remember, no absolute skill path to prepend.

## Prerequisites

- **tmux**
- **jq**
- **claude** CLI

## Setup

The CLI lives at `<skill>/scripts/csd`. Three top-level subcommands need the skill path:

- `csd launch <tmux-name> <cwd> [-- claude-args...]` — bootstrap a worker
- `csd list [--all]` — enumerate workers
- `csd grant-consent` — one-time consent for `--dangerously-skip-permissions`

Once a worker is launched, capture the shim path it prints to stdout and use it for everything else.

```bash
SKILL=/abs/path/to/skill/scripts
$SKILL/csd grant-consent          # one-time per machine
WORKER=$($SKILL/csd launch my-task /path/to/project)
# $WORKER is now /tmp/claude-workers/bin/my-task
```

The shim path is deterministic — if you know the tmux name, the path is `/tmp/claude-workers/bin/<tmux-name>`. You don't need to keep the variable around if the name is memorable.

## Workflow

### 1. Launch

```bash
WORKER=$($SKILL/csd launch my-task /path/to/project)
```

`csd launch`:
- Writes a meta file and a 3-line shim at `/tmp/claude-workers/bin/my-task`
- Starts tmux + claude with the plugin loaded
- Waits up to 30s for `session_start`
- Prints the shim path on stdout (one line)
- Prints a "Worker launched" panel on stderr including a `reproduce:` line with the exact relaunch command

Pass claude CLI args after a `--` separator:
```bash
WORKER=$($SKILL/csd launch my-task /path/to/project -- --model sonnet)
```

### 2. Converse (the typical case)

```bash
RESPONSE=$($WORKER converse "Refactor the auth module" 300)
echo "$RESPONSE"
```

`converse` sends the prompt, waits for the worker to finish, and returns the final assistant text. For tool-heavy turns where the bare text strips the interesting part, use `--with-turn` to get the full markdown:

```bash
TURN=$($WORKER converse --with-turn "Run the failing tests" 600)
```

Multi-turn just works — the wait tracks turn boundaries automatically:

```bash
R1=$($WORKER converse "Write tests for the auth module" 300)
R2=$($WORKER converse "Add edge cases for expired tokens" 300)
```

### 3. Lower-level control

If you need to drive the worker more directly:

```bash
$WORKER send "Refactor the auth module"     # send without waiting
$WORKER wait-for-turn 300                    # block until stop or session_end
$WORKER status                               # idle | working | terminated | gone
$WORKER read-turn                            # last turn as markdown
$WORKER read-turn --full                     # with complete tool results
```

### 4. Watching what the worker does

Every tool call emits a `pre_tool_use` event with the tool name and input. Tail the event stream to watch in real time:

```bash
$WORKER read-events --follow &
MONITOR_PID=$!
# ... do other work ...
kill $MONITOR_PID
```

Or pull events after the fact:

```bash
$WORKER read-events                # all events
$WORKER read-events --last 5
$WORKER read-events --type pre_tool_use
```

`--type` accepts one of: `session_start`, `user_prompt_submit`, `pre_tool_use`, `stop`, `session_end`. Unknown event names fail fast.

If you see something you don't want, stop the worker:

```bash
$WORKER stop
```

### 5. Stop and clean up

```bash
$WORKER stop
```

Sends `/exit`, waits up to 10s for `session_end`, kills the tmux session if still running, and removes the meta, events, and shim files.

### 6. Hand off to a human

```bash
$WORKER handoff
```

Prints attach instructions for a human to take over the tmux session.

## Reference

```
csd launch <tmux-name> <cwd> [-- claude-args...]
csd list [--all]
csd grant-consent

$WORKER converse [--with-turn] <prompt> [timeout=120]
$WORKER send <prompt>
$WORKER wait-for-turn [timeout=60]
$WORKER status
$WORKER read-events [--last N] [--type T] [--follow]
$WORKER read-turn [--full]
$WORKER stop
$WORKER handoff
$WORKER session-id
$WORKER events-file
```

Run `csd help` for the same surface.

## Common Patterns

### Fan-Out: Multiple Workers in Parallel

```bash
W1=$($SKILL/csd launch worker-api ~/proj)
W2=$($SKILL/csd launch worker-ui ~/proj)

$W1 send "Add pagination to /users"
$W2 send "Add a loading spinner to the user list"

$W1 wait-for-turn 600
$W2 wait-for-turn 600

$W1 stop
$W2 stop
```

### Pipeline: Worker A produces, Worker B consumes

```bash
W1=$($SKILL/csd launch spec ~/proj)
$W1 converse "Write an OpenAPI spec for /users to /tmp/api.yaml" 300
$W1 stop

W2=$($SKILL/csd launch impl ~/proj)
$W2 converse "Implement the endpoint defined in /tmp/api.yaml" 600
$W2 stop
```

## Edge Cases

### Worker crashes mid-turn

`wait-for-turn` matches `stop` OR `session_end`, so it returns when the worker dies. Call `$WORKER status` afterward: if it's `gone`, the worker crashed.

### Lost the shim path

If you know the tmux name, the path is `/tmp/claude-workers/bin/<tmux-name>`. If you don't, `csd list` enumerates everything.

### Long prompts

`send` uses bracketed-paste, which handles multi-line and special characters. For prompts in the tens-of-KB range, write to a file and tell the worker to read it:

```bash
echo "Long instructions..." > /tmp/instructions.txt
$WORKER send "Read /tmp/instructions.txt and follow it"
```

## Important Notes

- **One controller per worker.** Two controllers driving the same tmux session will collide.
- **Workers don't share state with the controller** except via files on disk and the event stream.
- **Shim paths bake in absolute skill paths.** A plugin reinstall at a new location breaks live workers; relaunch them.
