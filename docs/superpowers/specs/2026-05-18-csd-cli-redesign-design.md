# csd CLI Redesign

Date: 2026-05-18
Status: Draft — awaiting approval

## Problem

The current claude-session-driver skill exposes 13 separate shell scripts under `skills/driving-claude-code-sessions/scripts/`. Agents using the skill repeatedly trip on:

1. **Skill-path preamble.** Every script call requires the absolute skill path. The SKILL.md spends a noticeable share of its prose explaining this. Bash tool calls don't share shell state, so the agent has to thread the path through every invocation.
2. **Worker handle threading.** Each script takes the worker handle as its first argument. With multi-worker controllers this is fine; with a single worker it's pure friction.
3. **Event-name knowledge.** `wait-for-event.sh <event-name>` accepts arbitrary strings. An agent recently invented `end_of_turn` (no such event) and the 60-minute timeout silently ate an hour of wall time. A fail-fast validator was added today, but the underlying surface still asks the agent to know event names by heart.

The redesign replaces the 13 scripts with a single `csd` CLI plus a per-worker shim file. The shim bakes in the worker handle and the absolute skill path. The CLI exposes intervention-named wait subcommands instead of raw event names.

## Goals

- One entrypoint to learn: `csd`.
- After launch, all per-worker operations go through a deterministic handle that requires no remembered state.
- Invalid event names disappear as a class of bug in the common path (`wait-for-turn` replaces `wait-for-event stop`).
- The reproduction command for a worker is visible in launch output.

## Non-goals

- Persistent global install (no symlink into `$PATH`, no package manager). Skill-path invocation is fine for the few bootstrap commands.
- Windows-specific work beyond what the existing polyglot hook wrapper already covers. A bash csd has the same OS requirements as today's scripts.
- Multi-controller workflows. One controller per worker remains the model.
- Per-event wait subcommands beyond `wait-for-turn`. Only intervention conditions get named waits.

## User-facing surface

### Top-level subcommands (skill-path required)

```
csd launch <tmux-name> <cwd> [-- claude-args...]
csd list [--all]
csd grant-consent
```

`csd launch` is the only command an agent invokes via the skill path more than once per worker lifetime. `list` and `grant-consent` are diagnostic/bootstrap. Note: `current` from the old surface is **removed** — it returns "most recently touched meta file," which silently misleads in multi-worker controllers. The honest answer is `csd list`.

### Per-worker subcommands (via shim, or `csd --worker <name> <sub>`)

```
$WORKER converse [--with-turn] <prompt> [timeout]
$WORKER send <prompt>
$WORKER wait-for-turn [timeout]
$WORKER status
$WORKER read-events [--last N] [--type T] [--follow]
$WORKER read-turn [--full]
$WORKER stop
$WORKER handoff
$WORKER session-id
$WORKER events-file
```

`wait-for-turn` is the only wait subcommand. It blocks until **either** `stop` or `session_end` is observed — i.e., the worker is idle (controller's turn) OR the worker died (controller needs to handle it). The controller calls `status` afterward to tell which.

`read-events --type <event>` keeps the raw event-name argument for advanced use, validated against the canonical event list using the `validate_event_type` helper added today.

### The shim

`/tmp/claude-workers/bin/<tmux-name>` — three-line bash file:

```bash
#!/bin/bash
exec /abs/path/to/skill/scripts/csd --worker <tmux-name> "$@"
```

Properties:
- **Deterministic path.** Knowing the tmux name is sufficient to reconstruct the handle.
- **Self-locating skill path.** Baked in at launch time, so the shim works regardless of where the caller's cwd is.
- **Created by `csd launch`, removed by `$WORKER stop`.** A crash that skips cleanup leaves the shim behind alongside meta/events; `csd list --all` surfaces these as `gone` workers.

## Internal architecture

`scripts/csd` is a single bash file. Subcommand logic is inlined as bash functions, not dispatched into other scripts. The script self-locates via `BASH_SOURCE[0]` so it can:

- Find `_lib.sh` next to itself (sourced for `resolve_session`, `validate_event_type`, `_CSD_VALID_EVENTS`).
- Bake its own absolute path into shims it writes.

`--worker <name>` is a top-level flag parsed before the subcommand. Top-level subcommands (`launch`, `list`, `grant-consent`) reject `--worker` if supplied. Per-worker subcommands require it; the shim supplies it implicitly. This keeps the dispatch logic predictable: parse `--worker`, dispatch on subcommand, raise a clear error if the combination doesn't match.

The launch flow:

1. Validate inputs. Tmux name must not collide with an existing live session. cwd must exist.
2. Create `/tmp/claude-workers/` and `/tmp/claude-workers/bin/` if needed.
3. Generate a session UUID. Write `<session-id>.meta` containing `tmux_name`, `session_id`, `cwd`, and the launch invocation (for the reproduce line).
4. Start the detached tmux session running `claude --dangerously-skip-permissions [extra args...]` with the plugin enabled.
5. Wait up to 30s for the `session_start` event.
6. Write the shim at `/tmp/claude-workers/bin/<tmux-name>`, `chmod +x`.
7. Print the shim path to **stdout** (one line). Print the panel to **stderr** (see below).

## Launch output

```
stdout: /tmp/claude-workers/bin/foo

stderr: Worker launched.
          tmux:       foo
          session_id: 7a3c-...
          events:     /tmp/claude-workers/7a3c-....events.jsonl
          reproduce:  csd launch foo /path/to/project -- --model sonnet
```

Agents that capture `$(csd launch ...)` get the handle as a clean string. Humans reading the terminal see the panel. The `reproduce` line spells out the exact relaunch command, derived from the stored invocation in `<session-id>.meta`. A `--json` flag swaps stdout to a JSON object with all fields for scripted use.

## Event handling

The canonical event list lives in `_lib.sh`:

```
session_start user_prompt_submit pre_tool_use stop session_end
```

`wait-for-turn` matches `stop` OR `session_end` and prints the matching event JSON to stdout. Exit 0 on match, exit 1 on timeout. The validator added today (`validate_event_type`) is unused in `wait-for-turn` (there's no event arg) but still guards `read-events --type`.

## Cleanup

`$WORKER stop`:

1. Sends `/exit` to the tmux session.
2. Waits up to 10s for `session_end`.
3. Kills the tmux session if still running.
4. Removes `<session-id>.meta`, `<session-id>.events.jsonl`, **and** `/tmp/claude-workers/bin/<tmux-name>`.

`csd list` enumerates alive workers (those with a live tmux session). `csd list --all` includes workers whose meta exists but whose tmux is gone — useful for cleanup detection.

## Migration

### Files

**New:**
- `skills/driving-claude-code-sessions/scripts/csd`

**Kept (no behavior change):**
- `skills/driving-claude-code-sessions/scripts/_lib.sh` — sourced by csd.
- `hooks/emit-event` — events still emit identically.
- `hooks/hooks.json` — unchanged.

**Deleted:**
- `launch-worker.sh`, `converse.sh`, `send-prompt.sh`, `wait-for-event.sh`, `read-events.sh`, `read-turn.sh`, `status.sh`, `stop-worker.sh`, `handoff.sh`, `list-workers.sh`, `current.sh`, `grant-consent.sh`

**Rewritten:**
- `skills/driving-claude-code-sessions/SKILL.md` — teaches csd exclusively. Drops the "prepend absolute skill path on every call" preamble (only `csd launch`/`list`/`grant-consent` need it). Drops the script reference table. The events table moves to a small footnote about `read-events --type`.
- `tests/test-*.sh` — each existing test maps to its csd-subcommand equivalent. Tests now invoke `csd <sub>` rather than `scripts/<sub>.sh`.

### Test additions

- `csd launch` writes a valid, executable shim at `/tmp/claude-workers/bin/<tmux-name>`.
- The shim correctly `exec`s into csd with `--worker` baked in (verified by calling a no-side-effect subcommand like `session-id` through the shim).
- `csd launch` stdout is exactly the shim path (one line, no trailing whitespace beyond a newline).
- `csd launch` stderr contains the `reproduce:` line with the exact invocation.
- `wait-for-turn` returns when only `stop` is emitted.
- `wait-for-turn` returns when only `session_end` is emitted (worker died).
- `csd list` output shape (header + rows; one row per alive worker).
- `csd list --all` includes dead workers.
- `csd <worker> stop` removes the shim along with meta and events.

### Implementation order (single PR, logical chunks)

1. Write `csd` with all subcommands, alongside existing scripts (parallel surface, no removals yet). Get it loading and self-locating cleanly.
2. Rewrite the test suite to target csd. Run until green.
3. Delete old `scripts/*.sh` files.
4. Rewrite `SKILL.md`.
5. Update `CHANGELOG.md`.

## Risks

- **Single-file bash growth.** csd will be ~400 lines. Mitigated by keeping each subcommand as a small bash function and sharing logic via `_lib.sh`.
- **Shim staleness if skill path moves.** A shim bakes in the absolute skill path. If the plugin is reinstalled at a new location while a worker is alive, the shim breaks. Acceptable — workers are ephemeral, and the failure mode is loud (shim fails on first call).
- **Discovery of the shim path.** Agents must learn that `/tmp/claude-workers/bin/<tmux-name>` is the canonical handle. The SKILL.md rewrite leans on this prominently, and `csd launch` prints the path on stdout so capturing it is trivial.

## Open questions

None at this point. All earlier design forks (per-event subcommands vs intervention-named, generated standalone vs shim, folding non-worker ops into csd, dropping `current`) are resolved in the sections above.
