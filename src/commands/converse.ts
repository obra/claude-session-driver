import { existsSync, readFileSync } from 'node:fs';
import { dumpConverseDiag } from '../core/diagnostics.js';
import { readRawLines } from '../core/event-log.js';
import { eventsPath } from '../core/paths.js';
import type { Runner } from '../core/proc.js';
import { assistantText, renderTurnForCommand } from '../core/transcript.js';
import type { CommandContext, CommandResult } from './context.js';
import { resolveWorker } from './context.js';
import { cmdSend, isDeriveFirst, type SendOpts } from './send.js';
import { cmdWaitForTurn } from './wait-for-turn.js';

const sleep = (ms: number): Promise<void> =>
  new Promise((r) => setTimeout(r, ms));

export interface ConverseOpts {
  /** Render the full markdown turn instead of just the last assistant text. */
  withTurn?: boolean;
  /** Wait-for-turn absolute timeout in SECONDS (default 120). */
  timeout?: number;
  /**
   * Optional idle timeout in SECONDS, forwarded to cmdWaitForTurn: fail the turn
   * wait after this many seconds with no new worker events (any event resets
   * it). The absolute `timeout` stays the hard ceiling. Unset → absolute only.
   */
  idleTimeout?: number;
  /** Knobs forwarded to cmdSend (keeps submission confirm fast in tests). */
  sendOpts?: SendOpts;
  /** Poll interval forwarded to cmdWaitForTurn, ms. */
  waitPollMs?: number;
  /** Post-turn assistant-text poll attempts (default 20). */
  postPollCount?: number;
  /** Post-turn poll interval, ms (default 100). */
  postPollMs?: number;
  /** Injectable timestamp for diagnostics (default ISO now). */
  now?: () => string;
  /** Injectable process runner for the diagnostics ps dump. */
  diagRun?: Runner;
}

/**
 * Read the transcript file (or '' if absent) at the given path.
 */
function readTranscript(file: string): string {
  return existsSync(file) ? readFileSync(file, 'utf8') : '';
}

/**
 * Send a prompt to a worker, wait for the turn to finish, and return the
 * worker's reply.
 *
 * Parity port of bash `cmd_converse`, made harness-aware. The bash version
 * detected "did the worker reply?" with claude-only jq counting the assistant
 * text messages; that recognized neither codex rollouts nor pi sessions, so
 * converse always timed out for those harnesses. Here the turn-complete signal
 * is harness-agnostic — `cmdWaitForTurn` blocks on the `stop`/`session_end`
 * event the worker emits after the prompt — and the reply text is extracted by
 * driving the worker's transcript through `driver.parseTurn` (the same
 * normalized turn model `read-turn` renders), then joining the assistant text.
 * On a wait-for-turn timeout or a no-reply timeout, dumps a diagnostic when
 * `CSD_CONVERSE_DIAG_FILE` is set.
 */
export async function cmdConverse(
  ctx: CommandContext,
  worker: string,
  prompt: string,
  opts: ConverseOpts,
): Promise<CommandResult> {
  const timeout = opts.timeout ?? 120;
  const postPollCount = opts.postPollCount ?? 20;
  const postPollMs = opts.postPollMs ?? 100;
  const now = opts.now ?? (() => new Date().toISOString());

  // A fresh derive worker (codex/pi) has no `<sid>.meta` until its first prompt
  // self-registers it; `worker` is the tmux_name. cmdSend's sendDeriveFirst
  // handles that pre-registration window (paste-by-name, poll for the meta), so
  // we MUST send before resolving — resolving first would fail `no worker known`
  // (the bug cmdSend already fixed for plain `send`). The events file starts
  // empty, so wait-for-turn scans this first turn from line 0 (afterLine = 0).
  //
  // For an assign worker (claude) or an already-registered derive worker we
  // resolve first — preserving bash's order, which validates the meta/cwd before
  // sending — then capture the pre-send events line and send.
  const deriveFirst = isDeriveFirst(ctx, worker);
  let afterLine = 0;
  if (!deriveFirst) {
    const pre = resolveWorker(ctx, worker);
    if ('code' in pre) return pre;
    if (!pre.meta.cwd) {
      return {
        stderr: 'Error: Could not determine working directory from meta file',
        code: 1,
      };
    }
    afterLine = readRawLines(eventsPath(ctx.workerDir, pre.sid)).length;
  }

  const sendResult = await cmdSend(ctx, worker, prompt, opts.sendOpts ?? {});
  if (sendResult.code !== 0) return sendResult;

  // Resolve now: for a derive worker the meta self-registered during the send.
  const resolved = resolveWorker(ctx, worker);
  if ('code' in resolved) return resolved;
  const { sid, meta } = resolved;

  if (!meta.cwd) {
    return {
      stderr: 'Error: Could not determine working directory from meta file',
      code: 1,
    };
  }

  const logFile = ctx.driver.transcriptPath(sid, meta.cwd, ctx.home);
  const eventFile = eventsPath(ctx.workerDir, sid);

  const diagDest = process.env.CSD_CONVERSE_DIAG_FILE;
  const dumpDiag = async (reason: string): Promise<string> => {
    if (!diagDest) return '';
    const ok = await dumpConverseDiag({
      sid,
      worker,
      tmuxName: meta.tmux_name,
      logFile,
      eventFile,
      timeout,
      dest: diagDest,
      reason,
      tmux: ctx.tmux,
      now,
      run: opts.diagRun,
    });
    return ok ? `\ncsd-diagnostic: ${diagDest}` : '';
  };

  const waitResult = await cmdWaitForTurn(ctx, worker, {
    timeout,
    idleTimeout: opts.idleTimeout,
    afterLine,
    pollMs: opts.waitPollMs,
  });
  if (waitResult.code !== 0) {
    const diag = await dumpDiag('wait_for_turn_timeout');
    return {
      stderr: `Error: Worker did not finish within ${timeout}s${diag}`,
      code: 1,
    };
  }

  // The turn ended (wait-for-turn saw a stop/session_end after the prompt). The
  // transcript may lag the event by a beat, so poll it, parsing the latest turn
  // through the harness driver until the assistant text is present.
  for (let i = 0; i < postPollCount; i++) {
    const transcript = readTranscript(logFile);
    if (transcript.length > 0) {
      const turn = ctx.driver.parseTurn(transcript);
      if (turn.length > 0) {
        if (opts.withTurn) {
          return {
            stdout: renderTurnForCommand(turn, { full: false }),
            code: 0,
          };
        }
        const response = assistantText(turn);
        if (response.length > 0) {
          return { stdout: response, code: 0 };
        }
      }
    }
    await sleep(postPollMs);
  }

  const diag = await dumpDiag('no_assistant_response');
  return {
    stderr: `Error: Timed out waiting for assistant response in session log${diag}`,
    code: 1,
  };
}
