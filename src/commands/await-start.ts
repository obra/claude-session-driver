import { readRawLines } from '../core/event-log.js';
import { eventsPath } from '../core/paths.js';
import { removeWorker } from '../core/worker-store.js';
import { parseEvent } from '../events.js';
import type { CommandContext } from './context.js';

const sleep = (ms: number): Promise<void> =>
  new Promise((r) => setTimeout(r, ms));

/**
 * The trust-dialog window and the proof-of-life window. Claude with plugins
 * loaded can take well over 5s to draw the trust dialog.
 */
const DEFAULT_TRUST_TIMEOUT_MS = 20_000;
const DEFAULT_START_TIMEOUT_MS = 30_000;
const DEFAULT_POLL_MS = 250;

export interface AwaitStartOpts {
  /** Trust-dialog window in ms. */
  trustTimeoutMs?: number;
  /** session_start window in ms (bash: 30s). */
  startTimeoutMs?: number;
  /** Poll interval in ms (bash: 250ms in phase 1, 500ms in phase 2). */
  pollMs?: number;
}

/**
 * Success carries no message; failure always carries the full stderr text the
 * caller should emit. The discriminated union makes that invariant type-enforced.
 */
export type AwaitStartResult =
  | { started: true }
  | { started: false; failureMessage: string };

function sawSessionStart(eventFile: string): boolean {
  return readRawLines(eventFile).some(
    (line) => parseEvent(line)?.event === 'session_start',
  );
}

/** Last `n` non-empty lines, trailing whitespace stripped (bash sed + tail -20). */
function paneTail(pane: string, n: number): string {
  return pane
    .split('\n')
    .map((line) => line.replace(/\s+$/, ''))
    .filter((line) => line.length > 0)
    .slice(-n)
    .join('\n');
}

/**
 * Accept any trust dialog, then block until the worker emits `session_start`.
 * Parity port of bash `_await_session_start` (csd:557-605).
 *
 * Lives in the command layer (not the driver) because it needs `ctx.tmux`
 * (capture/sendEnter) and `ctx.workerDir` (the events file) — context the
 * driver's `awaitReady(tmuxName, sessionId)` slot does not receive. The launch
 * command calls this directly for claude; Phase B/C will generalize the
 * proof-of-life wait through the driver for codex/pi.
 *
 * On timeout it tears the worker down (kill session, remove meta+events+shim)
 * and returns `started: false` with the failure text for the caller to print.
 */
/** Text of the menu option under the `❯` cursor, or '' if none is shown. */
function highlightedOption(pane: string): string {
  const line = pane.split('\n').find((l) => l.includes('❯'));
  return line ? line.slice(line.indexOf('❯') + 1).trim() : '';
}

export async function awaitSessionStart(
  ctx: CommandContext,
  tmuxName: string,
  sessionId: string,
  opts: AwaitStartOpts = {},
): Promise<AwaitStartResult> {
  const trustTimeoutMs = opts.trustTimeoutMs ?? DEFAULT_TRUST_TIMEOUT_MS;
  const startTimeoutMs = opts.startTimeoutMs ?? DEFAULT_START_TIMEOUT_MS;
  const pollMs = opts.pollMs ?? DEFAULT_POLL_MS;
  const eventFile = eventsPath(ctx.workerDir, sessionId);

  // Phase 1: trust-dialog accept (content-aware). Break early if the worker
  // already started (some launches never show the dialog).
  const trustDeadline = Date.now() + trustTimeoutMs;
  while (Date.now() < trustDeadline) {
    if (sawSessionStart(eventFile)) break;
    const pane = await ctx.tmux.capturePane(tmuxName);
    if (pane.includes('trust this folder')) {
      // Current Claude Code highlights "No, exit" by default, so Enter alone
      // would quit the worker. Move the cursor until a "Yes" option is
      // highlighted, then confirm.
      if (highlightedOption(pane).startsWith('No')) {
        await ctx.tmux.sendKey(tmuxName, 'Down');
      } else {
        await ctx.tmux.sendEnter(tmuxName);
        break;
      }
    }
    await sleep(pollMs);
  }

  // Phase 2: block until session_start.
  const startDeadline = Date.now() + startTimeoutMs;
  while (Date.now() < startDeadline) {
    if (sawSessionStart(eventFile)) {
      return { started: true };
    }
    await sleep(pollMs);
  }

  // Timeout: capture the pane tail, tear down, and hand the error to the caller.
  let tail = '';
  try {
    tail = paneTail(await ctx.tmux.capturePane(tmuxName), 20);
  } catch {
    // pane capture is best-effort; an empty tail is fine.
  }
  const lines = ['Error: Worker session failed to start within 30 seconds'];
  if (tail.length > 0) {
    lines.push(
      '',
      'Last visible content in the worker pane:',
      '----------',
      tail,
      '----------',
    );
  }

  await ctx.tmux.killSession(tmuxName);
  removeWorker(ctx.workerDir, sessionId, tmuxName);

  return { started: false, failureMessage: lines.join('\n') };
}
