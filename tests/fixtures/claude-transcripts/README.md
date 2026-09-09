# Claude terminal-evidence fixtures

These fixtures freeze narrowly scoped evidence for terminal-failure handling.
They are not a general Claude Code transcript schema.

## `response-stopped-arriving.jsonl`

- Source kind: redacted empirical Claude Code transcript.
- Source session: `0631000d-13c5-498d-8e4f-affc671cea95`.
- Runtime: Claude Code 2.1.247.
- Retained fields: active parent linkage, record type, assistant role, message
  identity, stop reason, and the structural `isApiErrorMessage: true` marker.
- Removed or replaced: working-directory and transcript paths, session ID,
  request/provider details, error text, thinking text, usage, and private
  message content. UUIDs are fixture-local replacements.
- Assertion strength: proves that this runtime persisted a terminal assistant
  record whose structural API-error marker was true. It does not prove that
  every provider failure uses this fallback path.

## `interrupted.jsonl`

- Source kind: redacted empirical disposable-session lab.
- Capture date: 2026-08-30.
- Runtime: Claude Code 2.1.247.
- Input boundary: an empty temporary directory and a disposable CSD worker.
- Cancellation input: two programmatic `Escape` key sends did not cancel this
  runtime; `C-c` canceled the in-flight operation and returned the prompt.
- Retained fields: the active user-to-assistant linkage and the final assistant
  `tool_use` block.
- Removed or replaced: paths, session ID, prompt and response text, tool input,
  usage, attachments, sidecars, and provider details. UUIDs are fixture-local
  replacements.
- Observed event stream: `session_start`, `user_prompt_submit`, and
  `pre_tool_use`; no `Stop` event was emitted before the worker was closed.
- Assertion strength: freezes one incomplete tool-use tail after controller
  cancellation. It contains no dedicated interruption marker and must not be
  used to infer interruption or successful completion in general.

## Hook payloads

`../hooks/stop-failure.json` and
`../hooks/stop-with-background-work.json` are synthetic payloads copied from
the official Claude Code hooks reference mirrored on 2026-07-31. The source
sections are `StopFailure input` and `Stop input`, respectively. Identifiers,
paths, and free text are synthetic. These payloads establish documented hook
shape, not observed delivery behavior.
