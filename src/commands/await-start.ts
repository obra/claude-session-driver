import { readRawLines } from '../core/event-log.js';
import { eventsPath } from '../core/paths.js';
import { shellQuote } from '../core/shell.js';
import { removeWorker } from '../core/worker-store.js';
import { hasWorkspaceTrustGrant } from '../core/workspace-trust.js';
import { parseEvent } from '../events.js';
import type { CommandContext } from './context.js';

const sleep = (ms: number): Promise<void> =>
  new Promise((r) => setTimeout(r, ms));

const DEFAULT_START_TIMEOUT_MS = 30_000;
const DEFAULT_POLL_MS = 250;

export interface AwaitStartOpts {
  /** Canonical workspace path the worker was launched in. */
  cwd: string;
  /** CSD command path used to render the exact grant command. */
  csdPath: string;
  /** Ignore event-log lines that existed before this launch/adopt attempt. */
  afterLine: number;
  /** session_start window in ms (bash: 30s). */
  startTimeoutMs?: number;
  /** Poll interval in ms (bash: 250ms in phase 1, 500ms in phase 2). */
  pollMs?: number;
}

const WORKSPACE_TRUST_PROMPT =
  /trust this folder|trust the files in this folder/i;

function grantCommand(csdPath: string, cwd: string): string {
  const command = /\.[cm]?js$/.test(csdPath)
    ? `node ${shellQuote(csdPath)}`
    : shellQuote(csdPath);
  return `${command} grant-workspace-trust ${shellQuote(cwd)}`;
}

/**
 * Success carries no message; failure always carries the full stderr text the
 * caller should emit. The discriminated union makes that invariant type-enforced.
 */
export type AwaitStartResult =
  | { started: true }
  | { started: false; failureMessage: string };

function sawSessionStart(eventFile: string, afterLine: number): boolean {
  return readRawLines(eventFile)
    .slice(afterLine)
    .some((line) => parseEvent(line)?.event === 'session_start');
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
 * Block until the worker emits `session_start`, watching for trust prompts for
 * the full proof-of-life window. A prompt is accepted only for a CSD-granted
 * canonical workspace; otherwise the worker is torn down immediately.
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
export async function awaitSessionStart(
  ctx: CommandContext,
  tmuxName: string,
  sessionId: string,
  opts: AwaitStartOpts,
): Promise<AwaitStartResult> {
  const startTimeoutMs = opts.startTimeoutMs ?? DEFAULT_START_TIMEOUT_MS;
  const pollMs = opts.pollMs ?? DEFAULT_POLL_MS;
  const eventFile = eventsPath(ctx.workerDir, sessionId);

  const startDeadline = Date.now() + startTimeoutMs;
  let workspaceTrustHandled = false;
  while (Date.now() < startDeadline) {
    if (sawSessionStart(eventFile, opts.afterLine)) {
      return { started: true };
    }

    let pane = '';
    try {
      pane = await ctx.tmux.capturePane(tmuxName);
    } catch {
      // Pane capture can race startup; keep waiting for the event proof.
    }
    if (!workspaceTrustHandled && WORKSPACE_TRUST_PROMPT.test(pane)) {
      if (!hasWorkspaceTrustGrant(ctx.home, opts.cwd)) {
        await ctx.tmux.killSession(tmuxName);
        removeWorker(ctx.workerDir, sessionId, tmuxName);
        return {
          started: false,
          failureMessage: [
            `Error: Claude requires workspace trust for ${opts.cwd}.`,
            'CSD did not accept the prompt because this canonical workspace has no grant.',
            `Run interactively: ${grantCommand(opts.csdPath, opts.cwd)}`,
            'Then launch or adopt the worker again.',
          ].join('\n'),
        };
      }
      await ctx.tmux.sendEnter(tmuxName);
      workspaceTrustHandled = true;
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
