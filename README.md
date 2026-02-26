# claude-session-driver

Turn one Claude Code session into a project manager that delegates tasks to other Claude Code sessions.

## Why

A single Claude session works on one task at a time. With this plugin, a controller session launches worker sessions in tmux, assigns each a task, monitors their progress, reviews their tool calls, and collects results. Workers run in parallel. The controller decides what to do with their output.

## How It Works

Each worker session loads hooks that write lifecycle events to a JSONL file: session start, prompt submitted, tool use, stop, and session end. A PreToolUse hook pauses before every tool call, giving the controller a window to approve or deny it. If the controller does not respond within the timeout, the tool call proceeds.

The controller orchestrates workers through shell scripts that manage tmux sessions, poll events, read conversation logs, and clean up.

When `launch-worker.sh` runs inside tmux, it namespaces worker session names with the current session by default (for example, `fresh-worker-1`). This keeps worker sessions grouped with the coordinator context. Set `CLAUDE_SESSION_DRIVER_TMUX_NAMESPACE_MODE=off` to disable, `CLAUDE_SESSION_DRIVER_TMUX_NAMESPACE` to override the namespace root, and `CLAUDE_SESSION_DRIVER_TMUX_NAMESPACE_DELIM` to change the separator. Outside tmux, single-session namespace inference is disabled by default; enable it explicitly with `CLAUDE_SESSION_DRIVER_INFER_NAMESPACE=true` if you want that behavior. To launch workers via a different command, set `CLAUDE_SESSION_DRIVER_LAUNCH_CMD` to an executable name or path.

Set `CLAUDE_SESSION_DRIVER_TMUX_SCOPE=window` to launch workers as windows in the parent tmux session (window-level orchestration). The default scope is `session`.

`launch-worker.sh` returns both the requested tmux name and resolved `tmux_name` (plus `tmux_scope`); use the resolved `tmux_name` for follow-up commands. `send-prompt.sh` also accepts an optional `session_id` argument for deterministic targeting when requested names collide across namespaces.

## Installation

```bash
claude plugin install claude-session-driver@superpowers-marketplace
```

If your marketplace cache predates this plugin, update it first:

```bash
claude plugin marketplace update superpowers-marketplace
```

Requires **tmux**, **jq**, and the **claude** CLI.

## Usage

Install the plugin and ask Claude to manage a project. The `driving-claude-code-sessions` skill provides orchestration patterns:

- **Delegate and wait:** Launch a worker, assign a task, read the result.
- **Fan out:** Launch several workers on independent tasks, wait for all to finish.
- **Pipeline:** Chain workers so each builds on the previous worker's output.
- **Supervise:** Hold a multi-turn conversation with a worker, reviewing each response.
- **Hand off:** Pass a running worker session to a human operator in tmux.

## Scripts

| Script | Purpose |
|--------|---------|
| `launch-worker.sh` | Start a worker in tmux (session or window scope) |
| `converse.sh` | Send a prompt, wait, return the response |
| `send-prompt.sh` | Send a prompt without waiting (`<tmux-name> <prompt> [session-id]`) |
| `wait-for-event.sh` | Block until a lifecycle event appears |
| `read-events.sh` | Read and filter the event stream |
| `read-turn.sh` | Format the last turn as markdown |
| `stop-worker.sh` | Stop a worker and clean up |
| `approve-tool.sh` | Approve or deny a pending tool call |

## License

MIT
