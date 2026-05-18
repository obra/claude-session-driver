# Changelog

## [3.0.0] - 2026-05-18

### Breaking changes
- Replaced 12 per-operation scripts with a single `csd` CLI at
  `skills/driving-claude-code-sessions/scripts/csd`. The old scripts
  (`launch-worker.sh`, `converse.sh`, `send-prompt.sh`,
  `wait-for-event.sh`, `read-events.sh`, `read-turn.sh`, `status.sh`,
  `stop-worker.sh`, `handoff.sh`, `list-workers.sh`, `current.sh`,
  `grant-consent.sh`) are removed.
- `csd launch` writes a per-worker shim at
  `/tmp/claude-workers/bin/<tmux-name>` and prints that path on stdout.
  All per-worker operations go through the shim — see the rewritten
  SKILL.md for the new workflow.
- `wait-for-event` is replaced by `wait-for-turn`, which matches `stop`
  OR `session_end` (the only two events that signal "controller's
  turn"). Raw-event waits are no longer supported; use
  `$WORKER read-events --type T --follow` if you need ambient
  observation.
- `current` is removed — it returned "most-recently-touched meta file,"
  which silently misleads in multi-worker controllers. Use `csd list`.
- The meta file format gains `cwd` (was already present) and
  `invocation` (new) fields. Old workers from prior versions are not
  upgraded; relaunch them.

## [2.0.1] - 2026-05-17

### Fixed
- Workers no longer hang when the worker (or a subagent it spawns via the
  `Agent` tool) calls `AskUserQuestion`. There is no human at a worker's
  terminal to answer the modal, so the dialog would render in the worker's
  tmux pane and block the turn forever — no `stop` event would fire, the
  controller's wait would time out, and the worker would be wedged.
  `launch-worker.sh` now passes `--disallowed-tools AskUserQuestion` to
  the worker's `claude` invocation, which takes the tool off the menu
  entirely and (verified) propagates to spawned subagents as well.

## [2.0.0] - 2026-05-15

### Changed
- **Dropped the controller-side tool-call approval gate.** Workers run with
  `--dangerously-skip-permissions` and execute tool calls without prompting;
  the plugin no longer pretends otherwise. Empirical testing confirmed that
  Claude Code ignores hook-returned `permissionDecision` values under that
  flag, so the previous `pre_tool_use` → poll-for-`tool-decision` →
  allow/deny dance was cosmetic. Removing the fake gate makes the threat
  model honest: a worker does whatever its prompt tells it to do, and the
  controller's job is to choose its prompts carefully and watch the event
  stream.
- The `PreToolUse` hook is now observation-only. It still emits a
  `pre_tool_use` event (with `tool` and `tool_input` fields) to the event
  stream so a controller can monitor what each worker is doing. The
  `approve-tool` hook is gone — `emit-event` handles every lifecycle hook.
- `scripts/grant-consent.sh` rewrites the consent screen to be accurate
  about what the plugin actually does: workers run in bypass mode, the
  hook is for observation, and there is no per-call gating. Existing
  consent files remain valid since the underlying threat model
  (`--dangerously-skip-permissions`) hasn't changed.
- `scripts/status.sh` no longer returns `awaiting-approval`; the four
  remaining states are `idle | working | terminated | gone` (plus
  `unknown` when the events file hasn't been created yet).

### Removed
- `scripts/approve-tool.sh` — controller-side decision writer is no
  longer meaningful. **Breaking for anyone scripting against it.**
- `hooks/approve-tool` — replaced by `hooks/emit-event` handling
  `PreToolUse`.
- `CLAUDE_SESSION_DRIVER_APPROVAL_TIMEOUT` env var — there's no decision
  to wait for, so the timeout has no purpose.
- `/tmp/claude-workers/<id>.tool-pending` and `.tool-decision` files no
  longer exist.

## [1.2.0] - 2026-05-13

### Changed
- **Scripts directory moved into the skill.** Per the
  [agent-skills spec](https://agentskills.io/specification), bundled scripts
  belong in `<skill>/scripts/`. Helper scripts have moved from `scripts/`
  (plugin root) to `skills/driving-claude-code-sessions/scripts/`. The
  SKILL.md now uses bare relative paths (`scripts/launch-worker.sh`) and
  instructs the controller to prepend this skill's absolute base path when
  invoking via the Bash tool — matching the spec's "resolve relative paths
  against the skill's directory, use absolute paths in tool calls" rule.
  **Breaking for anyone scripting against the old `<plugin-root>/scripts/`
  path**; update references to point at the skill's scripts directory.
- **Every script accepts either `session_id` or `tmux_name`** as the worker
  handle. `wait-for-event.sh`, `read-events.sh`, `read-turn.sh`,
  `approve-tool.sh`, `converse.sh`, and `stop-worker.sh` all share a
  resolver (`scripts/_lib.sh`) that looks up whichever form wasn't passed
  via `/tmp/claude-workers/<id>.meta`. Cuts the bookkeeping a controller has
  to thread through call chains.

### Added
- `converse.sh --with-turn` returns the full markdown turn (tool calls,
  results, thinking, final text) via `read-turn.sh` instead of just the final
  assistant text. Useful when the worker is doing tool work and the bare
  text response strips out the interesting part.
- `list-workers.sh` shows alive workers by default; `--all` includes dead
  ones (meta files left behind after tmux session went away). Pruning dead
  workers is `stop-worker.sh <id>` on each — it cleans up files even when
  the tmux session is already gone.
- `current.sh` prints the session_id of the most recently launched worker —
  for one-worker flows where threading the UUID through every call is
  overhead.
- `status.sh <worker>` returns one of `idle | working | awaiting-approval
  | terminated | gone | unknown`. Use before sending a follow-up prompt to
  avoid racing the worker mid-thought when using `send-prompt.sh` +
  `wait-for-event.sh` directly rather than `converse.sh`.
- `handoff.sh <worker>` prints a ready-to-paste handoff message with the
  attach command, detach instructions, and a reminder not to stop the
  worker mid-handoff.

### Removed
- Legacy `<tmux-name> <session-id>` two-arg form for `converse.sh` and
  `stop-worker.sh`. With the resolver in place these are redundant; both now
  take a single worker handle (either form).

## [1.0.2] - 2026-05-13

### Fixed
- **SUP-239**: send-prompt.sh now wraps prompt text in bracketed-paste
  markers (\x1B[200~ ... \x1B[201~) and inserts a 100ms gap before Enter,
  matching the pattern Anthropic's own SDK uses to drive a Claude Code TUI.
  Long prompts (30+ lines, unicode) no longer intermittently stick in the
  worker's input box without submitting.
- **#9**: emit-event and approve-tool hooks no longer hang indefinitely
  when stdin is never closed. Replaced unbounded `cat` with `read -t 5 -d ''`,
  exit-0 on empty input. approve-tool additionally emits an explicit deny
  decision on empty or unparseable stdin so a worker running with
  --dangerously-skip-permissions can't accidentally auto-approve tool calls
  when the hook payload is malformed.
- **#14, #15**: hooks/run-hook.cmd polyglot wrapper for cross-platform
  invocation. Quotes `${CLAUDE_PLUGIN_ROOT}` to survive Windows paths with
  spaces and locates `bash.exe` via Git for Windows install paths so hooks
  run when Claude Code's hook PATH doesn't include bash. Hook scripts
  (emit-event, approve-tool) renamed to extensionless filenames so Windows
  auto-detection doesn't double-invoke them.
- **#11**: launch-worker.sh now works when invoked from inside another
  Claude session. Blanks the two env vars that break a nested worker
  (CLAUDE_CODE_SSE_PORT, CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST) via
  `tmux -e VAR=`. Passes `--settings '{"skipDangerousModePermissionPrompt":true}'`
  to silence the bypass-permissions warning dialog. Content-aware accept
  of the workspace-trust dialog only when it actually appears, so other
  dialogs (onboarding, theme picker) surface in the timeout error with
  `tmux capture-pane` output instead of getting auto-dismissed. On
  wait-for-event timeout, dumps the worker pane to stderr so the user can
  see what's blocking.

### Added
- One-time consent flow for running workers with
  --dangerously-skip-permissions. A new `scripts/grant-consent.sh` walks
  the user through what the plugin does and records acceptance in
  `~/.claude/.claude-session-driver-consent`. launch-worker.sh refuses to
  spawn workers until the dotfile exists, pointing the user at
  grant-consent.sh in the error message. Existing users will need to run
  `bash scripts/grant-consent.sh` once after updating.

## [1.0.1] - 2026-02-22

### Fixed
- Hooks no longer fire in non-worker sessions. Previously, the PreToolUse
  hook polled for 30 seconds on every tool call even in normal interactive
  and --dangerously-skip-permissions sessions. Hooks now check for the .meta
  file created by launch-worker.sh and exit immediately when absent.

## [1.0.0] - 2026-02-19

### Added
- Initial release: launch, control, and monitor Claude Code worker sessions
  via tmux with lifecycle event hooks and controller-gated tool approval.
