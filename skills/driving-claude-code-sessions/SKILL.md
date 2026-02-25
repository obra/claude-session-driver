---
name: driving-claude-code-sessions
description: Use when acting as a project manager that delegates tasks to other Claude Code sessions - launch workers, assign them work, monitor progress, review their tool calls, and collect results
---

# Driving Claude Code Sessions

## Overview

You can launch other Claude Code sessions as "workers" in tmux, send them prompts, monitor their progress through lifecycle events, read their output, and hand them off to a human operator. This gives you the ability to delegate work, run tasks in parallel, or set up supervised workflows.

Workers are full interactive Claude Code sessions launched with `--dangerously-skip-permissions` so they never block on interactive permission prompts. A plugin (claude-session-driver) injects hooks that emit lifecycle events to a JSONL file, which you poll to track worker state. A PreToolUse hook gives the controller a window to inspect and approve or deny every tool call before it executes. The scripts handle all the plumbing: tmux management, session IDs, event files, and cleanup.

## Prerequisites

These must be available on the system:
- **tmux** - for running worker sessions in detached terminals
- **jq** - for parsing JSON output from scripts and event files
- **claude** CLI - the Claude Code binary

## Setup

All scripts live at `../../scripts/` relative to this skill's base directory. Set a convenience variable:

```bash
SCRIPTS="<this-skill's-base-directory>/plugin/scripts"
```

## Workflow

### 1. Launch a Worker

```bash
RESULT=$("$SCRIPTS/launch-worker.sh" my-worker /path/to/project)
SESSION_ID=$(echo "$RESULT" | jq -r '.session_id')
TMUX_NAME=$(echo "$RESULT" | jq -r '.tmux_name')
```

The script:
- Creates a detached tmux session for requested name `my-worker` (actual name may be namespaced)
- Starts `claude` with the session-driver plugin loaded and `--dangerously-skip-permissions`
- Waits for the `session_start` event (up to 30s)
- Returns JSON with `session_id`, `tmux_name`, `requested_tmux_name`, and `events_file`

Use `tmux_name` from the launch result for all follow-up calls when possible.

Permission bypass is automatic. The worker's PreToolUse hook provides controller-based gating (see Tool Approval below), so the built-in interactive permission dialog is redundant.

Pass extra `claude` CLI arguments after the working directory:
```bash
# Use a specific model
RESULT=$("$SCRIPTS/launch-worker.sh" my-worker /path/to/project --model sonnet)
```

### 2. Converse (Preferred)

For most interactions, use `converse.sh` — it sends the prompt, waits for the worker to finish, and returns the assistant's response in one call:

```bash
RESPONSE=$("$SCRIPTS/converse.sh" "$TMUX_NAME" "$SESSION_ID" "Refactor the auth module to use JWT tokens" 300)
echo "$RESPONSE"
```

It handles `--after-line` tracking automatically, so multi-turn conversations just work:

```bash
R1=$("$SCRIPTS/converse.sh" "$TMUX_NAME" "$SESSION_ID" "Write tests for the auth module" 300)
R2=$("$SCRIPTS/converse.sh" "$TMUX_NAME" "$SESSION_ID" "Now add edge case tests for expired tokens" 300)
```

### 3. Send a Prompt (Low-Level)

For finer control, use the individual scripts. `send-prompt.sh` sends text without waiting:

```bash
"$SCRIPTS/send-prompt.sh" "$TMUX_NAME" "Refactor the auth module to use JWT tokens" "$SESSION_ID"
```

### 4. Wait for the Worker to Finish

```bash
"$SCRIPTS/wait-for-event.sh" "$SESSION_ID" stop 300
```

This blocks until the worker emits a `stop` event (meaning it finished processing and is waiting for input) or the timeout (in seconds) expires. Exit code 0 means the event arrived; exit code 1 means timeout.

The matching event JSON line is printed to stdout:
```json
{"ts":"2025-01-15T10:30:00Z","event":"stop"}
```

### 5. Read Worker Events

```bash
# All events
"$SCRIPTS/read-events.sh" "$SESSION_ID"

# Last 3 events
"$SCRIPTS/read-events.sh" "$SESSION_ID" --last 3

# Only stop events
"$SCRIPTS/read-events.sh" "$SESSION_ID" --type stop

# Follow in real-time (blocks -- run in background Bash job for monitoring)
"$SCRIPTS/read-events.sh" "$SESSION_ID" --follow &
MONITOR_PID=$!
# ... do other work ... then stop monitoring:
kill $MONITOR_PID 2>/dev/null
```

Event types emitted by the plugin:
| Event | Meaning | Extra fields |
|-------|---------|-------------|
| `session_start` | Worker session initialized | `cwd` |
| `user_prompt_submit` | A prompt was submitted to the worker | |
| `pre_tool_use` | Worker is about to call a tool | `tool`, `tool_input` |
| `stop` | Worker finished processing, waiting for input | |
| `session_end` | Worker session terminated | |

### 6. Read Worker Conversation Log

The worker's full conversation (prompts and responses) is stored in Claude's JSONL session log. The path uses an encoded form of the working directory where `/` becomes `-` with a leading `-`:

- `/Users/jesse/myproject` encodes to `-Users-jesse-myproject`

The log is at: `~/.claude/projects/<encoded-path>/<session-id>.jsonl`

To read the last assistant response:
```bash
ENCODED_PATH=$(echo "/path/to/project" | sed 's|/|-|g')
LOG_FILE=~/.claude/projects/${ENCODED_PATH}/${SESSION_ID}.jsonl
grep '"type":"assistant"' "$LOG_FILE" | tail -1 | jq -r '.message.content[] | select(.type=="text") | .text'
```

### 7. Stop a Worker

```bash
"$SCRIPTS/stop-worker.sh" my-worker "$SESSION_ID"
```

The script:
- Sends `/exit` to the tmux session
- Waits up to 10s for a `session_end` event
- Kills the tmux session if still running
- Cleans up event and metadata files in `/tmp/claude-workers/`

### 8. Hand Off to a Human

If you want a human to take over an active worker session:

```
The worker is running in tmux session 'my-worker'. You can:
- Watch live: tmux attach -t my-worker
- Take over: just start typing in the attached session
- Return to me: detach with Ctrl-B d
```

Leave the worker running. Do not stop it when handing off.

## Script Reference

| Script | Usage | Description |
|--------|-------|-------------|
| `converse.sh` | `<tmux-name> <session-id> <prompt> [timeout=120]` | Send prompt, wait, return response |
| `launch-worker.sh` | `<tmux-name> <working-dir> [claude-args...]` | Start a worker session |
| `send-prompt.sh` | `<tmux-name> <prompt-text> [session-id]` | Send a prompt to a worker |
| `wait-for-event.sh` | `<session-id> <event-type> [timeout=60] [--after-line N]` | Block until event or timeout |
| `read-events.sh` | `<session-id> [--last N] [--type T] [--follow]` | Read event stream |
| `stop-worker.sh` | `<tmux-name> <session-id>` | Gracefully stop and clean up |
| `approve-tool.sh` | `<session-id> <allow\|deny>` | Respond to a pending tool approval |
| `read-turn.sh` | `<session-id> [--full]` | Format last turn as markdown |

All scripts exit 0 on success, non-zero on failure. Error messages go to stderr.

## Common Patterns

### Single Worker: Delegate and Wait

```bash
RESULT=$("$SCRIPTS/launch-worker.sh" task-worker ~/myproject)
SESSION_ID=$(echo "$RESULT" | jq -r '.session_id')
TMUX_NAME=$(echo "$RESULT" | jq -r '.tmux_name')

"$SCRIPTS/send-prompt.sh" "$TMUX_NAME" "Run the test suite and fix any failures" "$SESSION_ID"
"$SCRIPTS/wait-for-event.sh" "$SESSION_ID" stop 600

# Read what happened, then clean up
"$SCRIPTS/read-events.sh" "$SESSION_ID"
"$SCRIPTS/stop-worker.sh" "$TMUX_NAME" "$SESSION_ID"
```

### Fan-Out: Multiple Workers in Parallel

```bash
# Launch workers for different tasks
R1=$("$SCRIPTS/launch-worker.sh" worker-api ~/myproject)
S1=$(echo "$R1" | jq -r '.session_id')
T1=$(echo "$R1" | jq -r '.tmux_name')

R2=$("$SCRIPTS/launch-worker.sh" worker-ui ~/myproject)
S2=$(echo "$R2" | jq -r '.session_id')
T2=$(echo "$R2" | jq -r '.tmux_name')

# Send each their task
"$SCRIPTS/send-prompt.sh" "$T1" "Add pagination to the /users endpoint" "$S1"
"$SCRIPTS/send-prompt.sh" "$T2" "Add a loading spinner to the user list page" "$S2"

# Wait for both (sequentially -- first one to finish unblocks its wait)
"$SCRIPTS/wait-for-event.sh" "$S1" stop 600
"$SCRIPTS/wait-for-event.sh" "$S2" stop 600

# Clean up
"$SCRIPTS/stop-worker.sh" "$T1" "$S1"
"$SCRIPTS/stop-worker.sh" "$T2" "$S2"
```

### Pipeline: Chained Workers

Pass one worker's output to the next:

```bash
# Worker 1: Generate an API spec
R1=$("$SCRIPTS/launch-worker.sh" worker-spec ~/myproject)
S1=$(echo "$R1" | jq -r '.session_id')
T1=$(echo "$R1" | jq -r '.tmux_name')
"$SCRIPTS/send-prompt.sh" "$T1" "Generate an OpenAPI spec for the users endpoint and save it to /tmp/api-spec.yaml" "$S1"
"$SCRIPTS/wait-for-event.sh" "$S1" stop 300

# Worker 2: Implement from the spec that Worker 1 produced
R2=$("$SCRIPTS/launch-worker.sh" worker-impl ~/myproject)
S2=$(echo "$R2" | jq -r '.session_id')
T2=$(echo "$R2" | jq -r '.tmux_name')
"$SCRIPTS/send-prompt.sh" "$T2" "Implement the API endpoint defined in /tmp/api-spec.yaml" "$S2"
"$SCRIPTS/wait-for-event.sh" "$S2" stop 600

# Clean up both
"$SCRIPTS/stop-worker.sh" "$T1" "$S1"
"$SCRIPTS/stop-worker.sh" "$T2" "$S2"
```

The key: workers communicate through files on disk. The controller orchestrates the sequence.

### Supervised: Multi-Turn Conversation

`converse.sh` handles `--after-line` tracking automatically, so multi-turn is straightforward:

```bash
RESULT=$("$SCRIPTS/launch-worker.sh" supervised ~/myproject)
SESSION_ID=$(echo "$RESULT" | jq -r '.session_id')
TMUX_NAME=$(echo "$RESULT" | jq -r '.tmux_name')

R1=$("$SCRIPTS/converse.sh" "$TMUX_NAME" "$SESSION_ID" "Write tests for the auth module" 300)
R2=$("$SCRIPTS/converse.sh" "$TMUX_NAME" "$SESSION_ID" "Now add edge case tests for expired tokens" 300)

"$SCRIPTS/stop-worker.sh" "$TMUX_NAME" "$SESSION_ID"
```

### Reviewing Worker Output

`converse.sh` returns only the final text response. To see the full turn (thinking, tool calls, results), use `read-turn.sh`:

```bash
# After a converse.sh call, review what the worker actually did
"$SCRIPTS/read-turn.sh" "$SESSION_ID"

# Show complete tool results (default truncates to 5 lines)
"$SCRIPTS/read-turn.sh" "$SESSION_ID" --full
```

Output is formatted as markdown: thinking in blockquotes, tool calls as code blocks, results in fenced blocks, and text responses inline.

## Edge Cases

### Worker Crashes or tmux Dies

If the tmux session disappears, `send-prompt.sh` will fail with "tmux session does not exist." Check before sending:
```bash
if ! tmux has-session -t "$TMUX_NAME" 2>/dev/null; then
  echo "Worker is gone -- need to relaunch"
fi
```

The event file at `/tmp/claude-workers/<session-id>.events.jsonl` will still contain events emitted before the crash.

### Timeout While Waiting

`wait-for-event.sh` exits 1 on timeout. The worker may still be running. Choose how to handle it:
- **Extend the wait:** Call `wait-for-event.sh` again with a new timeout
- **Give up:** Stop the worker with `stop-worker.sh`
- **Hand off:** Tell the human to take over

### Long Prompts

`send-prompt.sh` sends text literally via `tmux send-keys -l`, which handles multi-line text and special characters correctly. Very long prompts (tens of KB) may hit tmux buffer limits. For extremely large inputs, consider writing the instructions to a file and telling the worker to read it:
```bash
echo "Your detailed instructions here..." > /tmp/worker-instructions.txt
"$SCRIPTS/send-prompt.sh" "$TMUX_NAME" "Read /tmp/worker-instructions.txt and follow those instructions" "$SESSION_ID"
```

### Tool Approval

Every tool call the worker makes emits a `pre_tool_use` event and waits up to 30 seconds for a controller decision before auto-approving. This gives you a window to inspect and approve or deny each tool call.

**To monitor and auto-approve (default):** Do nothing. If no decision is written within the timeout, the tool call proceeds.

**To actively review tool calls:**

```bash
# Watch for pending tool approvals
PENDING_FILE="/tmp/claude-workers/${SESSION_ID}.tool-pending"

# Check if a tool call is waiting for approval
if [ -f "$PENDING_FILE" ]; then
  cat "$PENDING_FILE"  # Shows tool_name and tool_input

  # Approve it
  "$SCRIPTS/approve-tool.sh" "$SESSION_ID" allow

  # Or deny it
  "$SCRIPTS/approve-tool.sh" "$SESSION_ID" deny
fi
```

The timeout is configurable via the `CLAUDE_SESSION_DRIVER_APPROVAL_TIMEOUT` environment variable (default: 30 seconds). To change it, pass the env var when launching:
```bash
RESULT=$(CLAUDE_SESSION_DRIVER_APPROVAL_TIMEOUT=60 "$SCRIPTS/launch-worker.sh" my-worker ~/project)
```

## Important Notes

- **One controller per worker.** Do not have multiple controllers sending prompts to the same tmux session.
- **Clean up on failure.** If something goes wrong, always try to stop the worker and remove temp files. `stop-worker.sh` handles this, but if the script itself fails, clean up manually:
  ```bash
  tmux kill-session -t my-worker 2>/dev/null
  rm -f /tmp/claude-workers/<session-id>.events.jsonl
  rm -f /tmp/claude-workers/<session-id>.meta
  ```
- **Event files are append-only JSONL.** Each line is a self-contained JSON object with `ts` and `event` fields.
- **Workers are full Claude Code sessions.** They have their own tools, context, and conversation history. They do not share state with the controller except through files on disk and the event stream.
- **The tmux session name must be unique.** `launch-worker.sh` will fail if a session with that name already exists.
