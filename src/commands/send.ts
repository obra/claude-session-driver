import { classifyStatus, lastEvent, readRawLines } from '../core/event-log.js';
import { eventsPath } from '../core/paths.js';
import { resolveSession } from '../core/worker-store.js';
import { parseEvent } from '../events.js';
import type { CommandContext, CommandResult } from './context.js';
import { resolveWorker } from './context.js';

const ESC = '\x1b';
const PASTE_START = `${ESC}[200~`;
const PASTE_END = `${ESC}[201~`;

const sleep = (ms: number): Promise<void> =>
  new Promise((r) => setTimeout(r, ms));

/** Read an env var as a positive number, falling back to `dflt` if unset/invalid. */
function envNumber(name: string, dflt: number): number {
  const raw = process.env[name];
  if (raw === undefined) return dflt;
  const n = Number(raw);
  return Number.isFinite(n) ? n : dflt;
}

export interface SendOpts {
  /** Submission-confirm timeout in SECONDS (default 10, honours CSD_SUBMIT_TIMEOUT). */
  submitTimeout?: number;
  /**
   * Seconds between retry-Enter resends (default 2, honours CSD_SUBMIT_RETRY_INTERVAL).
   * Controls both the derive-worker pre-registration Enter cadence (sendDeriveFirst's
   * poll loop) and the post-paste submission-confirm cadence (confirmSubmission).
   */
  retryInterval?: number;
  /** Poll interval in ms (default 250). Small values keep tests fast. */
  pollMs?: number;
  /**
   * Pre-registration window timeout in SECONDS (default 15, honours
   * CSD_REGISTER_TIMEOUT). Only used on the first send to a derive worker
   * (codex), while polling for the hook-self-registered `<sid>.meta` to appear.
   */
  registerTimeout?: number;
  /** Poll interval in ms while waiting for the meta (default 250). */
  registerPollMs?: number;
}

/**
 * Port of the bash `_prompt_submitted_since`: has a `user_prompt_submit` event
 * appeared after line `beforeLine` of the events file? This is the worker's
 * ground-truth signal that the harness accepted a prompt.
 */
export function promptSubmittedSince(
  eventFile: string,
  beforeLine: number,
): boolean {
  const lines = readRawLines(eventFile);
  if (lines.length <= beforeLine) return false;
  return lines
    .slice(beforeLine)
    .some((line) => parseEvent(line)?.event === 'user_prompt_submit');
}

/**
 * Send a prompt to a worker as a bracketed paste, then confirm submission via
 * the `user_prompt_submit` event (issue #20).
 *
 * Parity port of bash `cmd_send`: the prompt is wrapped in bracketed-paste
 * markers (with any embedded markers stripped so a hostile prompt can't inject
 * its own) and sent as one literal send-keys. Enter is then sent and re-sent
 * every `retryInterval` seconds until the worker emits `user_prompt_submit`
 * (after the events file's pre-send line count) or `submitTimeout` elapses.
 */
/**
 * True when this is the FIRST prompt to a derive worker (codex/pi): the harness
 * mints its own id on the first prompt, so no `<sid>.meta` exists yet and the
 * worker can only be addressed by its tmux_name. `cmdSend` routes this to
 * `sendDeriveFirst` (paste-by-name, poll for the self-registered meta);
 * `cmdConverse` uses the same predicate to send-before-resolve. The claude
 * (assign) path and every subsequent send to a registered derive worker are
 * false here and take the normal resolve-then-send path.
 */
export function isDeriveFirst(ctx: CommandContext, worker: string): boolean {
  return (
    ctx.driver.idStrategy === 'derive' &&
    resolveSession(ctx.workerDir, worker) === null
  );
}

export async function cmdSend(
  ctx: CommandContext,
  worker: string,
  prompt: string,
  opts: SendOpts = {},
): Promise<CommandResult> {
  // Codex (derive) on the FIRST send: csd does not yet know the session id
  // (codex mints it on the first prompt) and so no `<sid>.meta` exists. The
  // paste itself triggers codex's SessionStart, whose hook self-registers the
  // meta; we then poll for it to learn the sid. The claude (assign) path, and
  // every subsequent send to an already-registered derive worker, take the
  // normal resolve-then-send path.
  if (isDeriveFirst(ctx, worker)) {
    return sendDeriveFirst(ctx, worker, prompt, opts);
  }

  const resolved = resolveWorker(ctx, worker);
  if ('code' in resolved) return resolved;
  const { sid, meta } = resolved;
  const tmuxName = meta.tmux_name;

  if (!(await ctx.tmux.hasSession(tmuxName))) {
    return {
      stderr: `Error: tmux session '${tmuxName}' does not exist`,
      code: 1,
    };
  }

  const eventFile = eventsPath(ctx.workerDir, sid);
  const beforeLine = readRawLines(eventFile).length;
  await pasteText(ctx, tmuxName, prompt);
  return confirmSubmission(ctx, tmuxName, eventFile, beforeLine, opts);
}

/**
 * The first send to a not-yet-registered derive worker (codex). `worker` is the
 * tmux_name (csd has no sid yet). We paste targeting tmux BY NAME to provoke
 * codex's SessionStart, poll for the hook-self-registered `<worker>.meta`, then
 * run the normal submission-confirm loop once the sid is known.
 */
async function sendDeriveFirst(
  ctx: CommandContext,
  worker: string,
  prompt: string,
  opts: SendOpts,
): Promise<CommandResult> {
  if (!(await ctx.tmux.hasSession(worker))) {
    return {
      stderr: `Error: tmux session '${worker}' does not exist`,
      code: 1,
    };
  }

  const registerTimeout =
    opts.registerTimeout ?? envNumber('CSD_REGISTER_TIMEOUT', 15);
  const registerPollMs = opts.registerPollMs ?? 250;
  const retryInterval =
    opts.retryInterval ?? envNumber('CSD_SUBMIT_RETRY_INTERVAL', 2);

  // Paste + Enter to provoke codex's first prompt: codex fires SessionStart (the
  // hook self-registers the meta) and accepts the prompt. There is no events
  // file yet, so the confirm loop will start from line 0. Re-send Enter on the
  // retry interval while polling, since an Enter sent before codex finished
  // converting the paste can be swallowed (issue #20).
  await pasteText(ctx, worker, prompt);
  await ctx.tmux.sendEnter(worker);

  const deadline = Date.now() + registerTimeout * 1000;
  let sinceEnter = Date.now();
  let sid = resolveSession(ctx.workerDir, worker);
  while (sid === null) {
    if (Date.now() >= deadline) {
      return {
        stderr: `Error: worker '${worker}' did not register within ${registerTimeout}s (codex did not emit SessionStart)`,
        code: 1,
      };
    }
    await sleep(registerPollMs);
    if (Date.now() - sinceEnter >= retryInterval * 1000) {
      await ctx.tmux.sendEnter(worker);
      sinceEnter = Date.now();
    }
    sid = resolveSession(ctx.workerDir, worker);
  }

  // confirmSubmission will send Enter again; the extra Enter is a safe no-op
  // once the prompt is already submitted (idempotent per issue #20).
  return confirmSubmission(
    ctx,
    worker,
    eventsPath(ctx.workerDir, sid),
    0,
    opts,
  );
}

/**
 * Send the prompt as one bracketed paste. Any embedded paste markers are
 * stripped first so a hostile prompt cannot inject its own paste boundaries.
 */
async function pasteText(
  ctx: CommandContext,
  tmuxName: string,
  prompt: string,
): Promise<void> {
  const safe = prompt.split(PASTE_END).join('').split(PASTE_START).join('');
  await ctx.tmux.sendText(tmuxName, PASTE_START + safe + PASTE_END);
}

/**
 * True when the worker's last event says it is still inside a turn. Pasting into
 * a worker in that state gets the prompt QUEUED (Claude Code shows "Press up to
 * edit queued messages"), and a queued prompt emits no `user_prompt_submit` of
 * its own — verified against Claude Code 2.1.237: the queued turn runs and
 * answers, but the only events written are the in-flight turn's, and one `stop`
 * closes both. Mirrors `status`' classification so the two never disagree.
 */
function workerMidTurn(eventFile: string): boolean {
  const last = lastEvent(eventFile);
  return last !== null && classifyStatus(last) === 'working';
}

/**
 * Send Enter and re-send it every `retryInterval` seconds until the worker emits
 * `user_prompt_submit` after `beforeLine`, or `submitTimeout` elapses. Shared by
 * the assign and derive paths.
 *
 * The harness converts the bracketed paste into a pending-input widget
 * asynchronously; an Enter sent too early can be swallowed (issue #20).
 *
 * Running out of time is not automatically a failure. If the worker is still
 * mid-turn the prompt was queued, and a queued prompt never emits its own
 * `user_prompt_submit` — so the event this loop waits for will never be written,
 * no matter how high `CSD_SUBMIT_TIMEOUT` is set. Report that as success with a
 * note rather than the #20 paste-swallowed error, whose "raise the timeout"
 * advice cannot help there.
 */
async function confirmSubmission(
  ctx: CommandContext,
  tmuxName: string,
  eventFile: string,
  beforeLine: number,
  opts: SendOpts,
): Promise<CommandResult> {
  const submitTimeout =
    opts.submitTimeout ?? envNumber('CSD_SUBMIT_TIMEOUT', 10);
  const retryInterval =
    opts.retryInterval ?? envNumber('CSD_SUBMIT_RETRY_INTERVAL', 2);
  const pollMs = opts.pollMs ?? 250;

  await ctx.tmux.sendEnter(tmuxName);
  const deadline = Date.now() + submitTimeout * 1000;
  let sinceEnter = Date.now();
  while (!promptSubmittedSince(eventFile, beforeLine)) {
    if (Date.now() >= deadline) {
      if (workerMidTurn(eventFile)) {
        return {
          stderr: `Note: worker '${tmuxName}' is mid-turn, so the prompt was queued behind the running turn. A queued prompt emits no user_prompt_submit of its own, so there is nothing further to confirm; it runs when the current turn ends. Use 'csd converse' (or 'csd wait-for-turn') if you need to wait for the reply.`,
          code: 0,
        };
      }
      return {
        stderr: `Error: prompt pasted but worker did not confirm submission within ${submitTimeout}s (issue #20). The tmux session may be slow to accept the paste; raise CSD_SUBMIT_TIMEOUT to allow more time.`,
        code: 1,
      };
    }
    await sleep(pollMs);
    if (Date.now() - sinceEnter >= retryInterval * 1000) {
      await ctx.tmux.sendEnter(tmuxName);
      sinceEnter = Date.now();
    }
  }

  return { code: 0 };
}
