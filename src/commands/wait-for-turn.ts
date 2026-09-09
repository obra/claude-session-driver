import { existsSync } from 'node:fs';
import { readRawLines } from '../core/event-log.js';
import { eventsPath } from '../core/paths.js';
import { readMeta, resolveSession } from '../core/worker-store.js';
import type { WorkerEvent } from '../events.js';
import { parseEvent } from '../events.js';
import type { CommandContext, CommandResult } from './context.js';

export interface WaitForTurnOpts {
  /** Timeout in SECONDS (default 60). */
  timeout?: number;
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
  return e === 'stop' || e === 'stop_failure' || e === 'session_end';
};

export interface WaitForTurnResult extends CommandResult {
  /** Parsed terminal event when the command observed one. */
  terminal?: WorkerEvent;
  /** Retry cursor: scan only lines after this baseline. */
  afterLine?: number;
  eventFile?: string;
  sid?: string;
}

export function formatStopFailure(
  worker: string,
  sid: string,
  event: Extract<WorkerEvent, { event: 'stop_failure' }>,
  eventFile: string,
): string {
  const lines = [
    'Error: Claude turn failed',
    `worker: ${worker}`,
    `session_id: ${sid}`,
    `error: ${event.error}`,
  ];
  if (event.error_details !== undefined) {
    lines.push(`error_details: ${event.error_details}`);
  }
  if (event.last_assistant_message !== undefined) {
    lines.push(`last_assistant_message: ${event.last_assistant_message}`);
  }
  if (event.transcript_path !== undefined) {
    lines.push(`transcript: ${event.transcript_path}`);
  }
  lines.push(`events: ${eventFile}`, 'worker remains reusable');
  return lines.join('\n');
}

/**
 * Block until the worker finishes a turn: the first `stop`, `stop_failure`, or
 * `session_end` event appended after the baseline. The baseline defaults to the
 * events file's current line count, so a bare `wait-for-turn` waits for the NEXT
 * turn-end rather than returning a stale one from a previous turn. Normal
 * completion emits the matching event's RAW JSONL line; StopFailure emits its
 * evidence on stderr with exit 3.
 *
 * A single deadline governs both the wait-for-file-to-exist phase and the
 * poll-for-turn-end phase. On the turn poll, only lines beyond what's already
 * been checked are scanned for the first matching event.
 */
export async function cmdWaitForTurn(
  ctx: CommandContext,
  worker: string,
  opts: WaitForTurnOpts,
): Promise<WaitForTurnResult> {
  const timeout = opts.timeout ?? 60;
  const pollMs = opts.pollMs ?? 500;

  const sid = resolveSession(ctx.workerDir, worker);
  if (sid === null) {
    return { stderr: `Error: no worker known as '${worker}'`, code: 1 };
  }
  const workerName = readMeta(ctx.workerDir, sid)?.tmux_name ?? worker;

  const eventFile = eventsPath(ctx.workerDir, sid);
  const deadline = Date.now() + timeout * 1000;

  while (!existsSync(eventFile)) {
    if (Date.now() >= deadline) {
      return {
        stderr: [
          `Timeout waiting for event file: ${eventFile}`,
          `worker: ${workerName}`,
          `session_id: ${sid}`,
          `retry_after_line: ${opts.afterLine ?? 0}`,
          `retry: wait-for-turn --after-line ${opts.afterLine ?? 0}`,
          'worker remains reusable',
        ].join('\n'),
        code: 124,
        afterLine: opts.afterLine ?? 0,
        eventFile,
        sid,
      };
    }
    await sleep(pollMs);
  }

  // Default baseline = current EOF, so a bare call waits for the next turn-end.
  let linesChecked = opts.afterLine ?? readRawLines(eventFile).length;
  while (Date.now() < deadline) {
    const lines = readRawLines(eventFile);
    if (lines.length > linesChecked) {
      const match = lines.slice(linesChecked).find(isTurnEnd);
      if (match !== undefined) {
        const terminal = parseEvent(match);
        if (terminal?.event === 'stop_failure') {
          return {
            stderr: formatStopFailure(workerName, sid, terminal, eventFile),
            code: 3,
            terminal,
            afterLine: linesChecked,
            eventFile,
            sid,
          };
        }
        if (terminal !== null) {
          return {
            stdout: match,
            code: 0,
            terminal,
            afterLine: linesChecked,
            eventFile,
            sid,
          };
        }
      }
      linesChecked = lines.length;
    }
    await sleep(pollMs);
  }

  return {
    stderr: [
      `Timeout waiting for turn (stop, stop_failure, or session_end) after ${timeout}s`,
      `worker: ${workerName}`,
      `session_id: ${sid}`,
      `events: ${eventFile}`,
      `retry_after_line: ${linesChecked}`,
      `retry: wait-for-turn --after-line ${linesChecked}`,
      'worker remains reusable',
    ].join('\n'),
    code: 124,
    afterLine: linesChecked,
    eventFile,
    sid,
  };
}
