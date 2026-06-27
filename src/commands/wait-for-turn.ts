import { existsSync } from 'node:fs';
import { readRawLines } from '../core/event-log.js';
import { eventsPath } from '../core/paths.js';
import { resolveSession } from '../core/worker-store.js';
import { parseEvent } from '../events.js';
import type { CommandContext, CommandResult } from './context.js';

export interface WaitForTurnOpts {
  /**
   * Absolute timeout in SECONDS (default 60): a hard ceiling on the whole wait,
   * regardless of activity. Unchanged from prior behaviour.
   */
  timeout?: number;
  /**
   * Optional idle timeout in SECONDS. When set, the wait ALSO fails after this
   * many seconds with no new worker events; any new event (e.g. a per-tool-call
   * `pre_tool_use`) resets it, so an actively-progressing turn survives up to
   * the absolute `timeout`. Unset → no idle limit (behaviour identical to
   * before): the absolute `timeout` is the only deadline.
   */
  idleTimeout?: number;
  /**
   * Skip this many leading lines of the events file before scanning for a
   * turn-end. Default: the file's current line count when the call starts — i.e.
   * block until the NEXT turn-end, not one already in the file from a previous
   * turn. (`converse` passes an explicit baseline captured before it sends.)
   */
  afterLine?: number;
  /** Poll interval in ms (default 500). Small values keep tests fast. */
  pollMs?: number;
}

const sleep = (ms: number): Promise<void> =>
  new Promise((r) => setTimeout(r, ms));

const isTurnEnd = (line: string): boolean => {
  const e = parseEvent(line)?.event;
  return e === 'stop' || e === 'session_end';
};

/**
 * Block until the worker finishes a turn: the first `stop` or `session_end`
 * event appended after the baseline. The baseline defaults to the events file's
 * current line count, so a bare `wait-for-turn` waits for the NEXT turn-end
 * rather than returning a stale one from a previous turn. Emits the matching
 * event's RAW JSONL line.
 *
 * Two deadlines bound the wait. The absolute `timeout` is a fixed ceiling on
 * the whole call (unchanged behaviour). The optional `idleTimeout`, when set,
 * also fails the wait after that many seconds with no new events — but every
 * batch of new events resets it, so an actively-progressing turn runs up to the
 * absolute ceiling and only a silent one is cut off early. On the turn poll,
 * only lines beyond what's already been checked are scanned for a match.
 */
export async function cmdWaitForTurn(
  ctx: CommandContext,
  worker: string,
  opts: WaitForTurnOpts,
): Promise<CommandResult> {
  const timeout = opts.timeout ?? 60;
  const idleTimeout = opts.idleTimeout;
  const pollMs = opts.pollMs ?? 500;

  const sid = resolveSession(ctx.workerDir, worker);
  if (sid === null) {
    return { stderr: `Error: no worker known as '${worker}'`, code: 1 };
  }

  const eventFile = eventsPath(ctx.workerDir, sid);
  const absoluteDeadline = Date.now() + timeout * 1000;
  let idleDeadline =
    idleTimeout !== undefined
      ? Date.now() + idleTimeout * 1000
      : Number.POSITIVE_INFINITY;

  while (!existsSync(eventFile)) {
    if (Date.now() >= absoluteDeadline) {
      return {
        stderr: `Timeout waiting for event file: ${eventFile}`,
        code: 1,
      };
    }
    await sleep(pollMs);
  }

  // Default baseline = current EOF, so a bare call waits for the next turn-end.
  let linesChecked = opts.afterLine ?? readRawLines(eventFile).length;
  while (Date.now() < absoluteDeadline && Date.now() < idleDeadline) {
    const lines = readRawLines(eventFile);
    if (lines.length > linesChecked) {
      const match = lines.slice(linesChecked).find(isTurnEnd);
      if (match !== undefined) {
        return { stdout: match, code: 0 };
      }
      linesChecked = lines.length;
      // New events = the worker is still making progress: reset the idle clock
      // (a no-op when no idle timeout was requested).
      if (idleTimeout !== undefined) {
        idleDeadline = Date.now() + idleTimeout * 1000;
      }
    }
    await sleep(pollMs);
  }

  if (idleTimeout !== undefined && idleDeadline <= absoluteDeadline) {
    return {
      stderr: `Timeout waiting for turn: no worker activity for ${idleTimeout}s`,
      code: 1,
    };
  }
  return {
    stderr: `Timeout waiting for turn (stop or session_end) after ${timeout}s`,
    code: 1,
  };
}
