# claude-session-driver

Turn one coding-agent session into a project manager that delegates tasks to other coding-agent sessions — Claude Code, Codex, or Pi.

## Why

A single coding-agent session works on one task at a time. With this plugin, a controller session launches worker sessions in tmux, assigns each a task, monitors their progress, and collects results. Workers run in parallel. The controller decides what to do with their output.

## How It Works

Workers run with permissions bypassed and execute tool calls without prompting. Each worker writes lifecycle events to a JSONL file — session start, prompt submitted, each tool call (with name and input), stop, API failure, and session end — so a controller can watch what each worker is doing. The events are observation-only; the plugin does not gate tool calls.

The controller drives three harnesses through one CLI (`csd`), chosen at launch with `--harness <claude|codex|pi>` (default `claude`):

- **Claude Code** and **Codex** emit events through their hook systems (node hook programs).
- **Pi** emits events through a native TypeScript extension `csd` loads into it.

Whichever harness you launch, the controller-facing command surface is **identical** — `launch`, `send`, `converse`, `wait-for-turn`, `read-turn`, `read-events`, `status`, `stop`, and `handoff` all behave the same. (`adopt` is the one exception: it's Claude-only, since Codex and Pi mint their own session ids and offer no resume-by-id.) The CLI manages tmux sessions, polls events, reads conversation logs, and cleans up.

## Installation

```bash
claude plugin install claude-session-driver@superpowers-marketplace
```

If your marketplace cache predates this plugin, update it first:

```bash
claude plugin marketplace update superpowers-marketplace
```

Requires **tmux** and a harness CLI — at least the one you launch: **claude** (default), **codex**, or **pi**. No `jq` and no bash hooks: `csd` is a TypeScript/node tool whose hooks are node programs (`node` is required, but it ships wherever Claude Code runs). Codex stages the operator's `~/.codex` auth into each worker; Pi stages `~/.pi/agent`.

## Usage

Install the plugin and ask Claude to manage a project. The `driving-claude-code-sessions` skill provides orchestration patterns:

- **Delegate and wait:** Launch a worker, assign a task, read the result.
- **Fan out:** Launch several workers on independent tasks, wait for all to finish.
- **Pipeline:** Chain workers so each builds on the previous worker's output.
- **Supervise:** Hold a multi-turn conversation with a worker, reviewing each response.
- **Hand off:** Pass a running worker session to a human operator in tmux.

See `skills/driving-claude-code-sessions/SKILL.md` for detailed usage patterns.

## CLI

All operations go through a single binary at `skills/driving-claude-code-sessions/scripts/csd`.

### Top-level subcommands

| Subcommand | Purpose |
|------------|---------|
| `csd launch [--harness <claude\|codex\|pi>] <name> <cwd> [-- harness-args...]` | Bootstrap a worker (harness defaults to `claude`); prints a shim path to stdout |
| `csd adopt <name> <cwd> <session-id> [-- claude-args...]` | Re-adopt an existing Claude session as a worker (claude-only) |
| `csd list [--all]` | List active (or all) workers |
| `csd grant-consent` | One-time consent flow (required before first launch) |
| `csd grant-workspace-trust <cwd>` | Interactively allow CSD to accept Claude's workspace trust prompt for one canonical directory |

`csd launch` prints the shim path to stdout (deterministic at `/tmp/csd-workers/bin/<name>`) and a human-readable panel to stderr. Capture it:

```bash
WORKER=$(csd launch my-worker /path/to/project)
```

The worker dir defaults to `/tmp/csd-workers` (renamed from `/tmp/claude-workers`; a back-compat symlink `/tmp/claude-workers → /tmp/csd-workers` is created when the default is in use). Override it with `CSD_WORKER_DIR`.

### Claude workspace trust

If Claude opens its workspace trust dialog, CSD accepts it only when that exact
canonical directory has a CSD-owned grant. Create one from an interactive
terminal:

```bash
csd grant-workspace-trust /path/to/project
```

The command resolves the directory with `realpath`, shows the canonical result,
and requires you to type that complete path exactly. It stores an owner-only,
hashed per-workspace record under `~/.claude/.claude-session-driver/`; it does
not directly edit Claude's `~/.claude.json`. This grant authorizes only CSD's
single Enter on a recognized workspace prompt; it is not Claude's trust record.

For a non-home directory, once CSD accepts the prompt, Claude records its own
native trust for that canonical path. That native record is independent: later
removing the CSD grant or changing repository contents does not revoke it. For
the home directory, Claude intentionally does not persist native trust and asks
again on every launch, so a home grant lets CSD confirm each new prompt.

CSD recognizes the prompt only when the same pane contains `Yes, I trust this
folder` and either `No, exit` or `No, continue without these permissions`.
Anything else fails closed: CSD sends no Enter and eventually reports the
visible pane on timeout. Smoke-test this detector after Claude Code upgrades
that may change startup UI wording. Without a grant, `launch` removes its new
worker; a failed `adopt` rolls back only state created by that attempt and
preserves inherited tmux, events, shim, and metadata. A workspace grant never
authorizes separate prompts such as external `CLAUDE.md` imports.

### Per-worker subcommands

Once you have a shim path, invoke it directly or use `csd --worker <name> <sub>`:

| Subcommand | Purpose |
|------------|---------|
| `$WORKER converse [--with-turn] <prompt> [timeout]` | Send a prompt, wait, and return the response or a visible terminal outcome |
| `$WORKER send <prompt>` | Send a prompt without waiting |
| `$WORKER wait-for-turn [timeout]` | Block until `stop`, `stop_failure`, or `session_end` |
| `$WORKER read-turn [--full]` | Format the last turn as markdown |
| `$WORKER read-events [--last N] [--type T] [--follow]` | Read and filter the event stream |
| `$WORKER status` | Print worker status (idle/working/terminated/gone) |
| `$WORKER stop` | Stop the worker and clean up |
| `$WORKER handoff` | Print tmux attach instructions for a human takeover |
| `$WORKER session-id` | Print the worker's session id |
| `$WORKER events-file` | Print the path to the JSONL event file |

### Terminal outcomes

Successful waits return exit 0. A Claude Code `StopFailure` is recorded as a
structured `stop_failure` event; `wait-for-turn` and `converse` return exit 3
and write the provider error evidence to stderr instead of presenting it as a
successful assistant response. If the caller's wait budget expires without
terminal evidence, they return exit 124 with the worker name, session ID, and
event path; `converse` also prints the transcript path.

For Claude `converse`, a missing `StopFailure` hook gets one bounded fallback.
Before sending, CSD finds the last complete UUID-bearing record inside a fixed
1 MiB capture window and retains its byte offsets and snapshot identity. On
timeout it revalidates that anchor without reading earlier bytes, then reads at
most 1 MiB after it. Exit 3 requires a non-sidechain API-error assistant whose
`parentUuid` ancestry reaches the anchor. An absent or mismatched anchor,
rewrite/truncation, oversized or malformed tail, orphan/sidechain error, unknown
UUID-bearing chain type, later substantive assistant output, or unmarked tail
remains exit 124. The fallback never treats transcript shape as proof of normal
completion.

When `wait-for-turn` exits 124, stderr includes `retry_after_line: N`. Retry
with `$WORKER wait-for-turn --after-line N` to keep a terminal event that arrives
after the first timeout visible; a bare retry would baseline at the new end of
the event file. `converse` exit 124 prints the same cursor plus the complete shim
command. Check `status` first, then use that exact command when the turn is still
working or when you need to consume a terminal event that landed after timeout.

Exit 3 and exit 124 leave the tmux worker alive and reusable. CSD does not retry
automatically. This release keeps the existing daemonless status vocabulary and
tabular `list` output; it does not add turn IDs, controller claims/correlation,
interruption classification, a journal, or a daemon.

### Environment variables

All optional. `csd help` shows the full list.

| Variable | Purpose |
|----------|---------|
| `CSD_CLAUDE_BIN` / `CSD_CODEX_BIN` / `CSD_PI_BIN` | Path to each harness binary (defaults `claude` / `codex` / `pi`, resolved via `PATH`) |
| `CSD_CODEX_MODEL` / `CSD_PI_MODEL` | Optional model override for codex / pi workers (unset = the harness default) |
| `CSD_WORKER_DIR` | Override the worker dir (default `/tmp/csd-workers`) |
| `CSD_CONVERSE_DIAG_FILE` | When set, `csd converse` writes a post-mortem diagnostic to this path on timeout |

### Design docs

- `docs/superpowers/specs/` — design specifications
- `docs/superpowers/plans/` — implementation plans

## License

MIT
