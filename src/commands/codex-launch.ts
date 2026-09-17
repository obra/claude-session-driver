/**
 * Codex launch-time tmux dances. Parity port of the bash codex driver's
 * `harness_post_launch` + `harness_await_ready` (drivers/codex.sh).
 *
 * These live in the command layer (not the HarnessDriver) because they need
 * `ctx.tmux` (capture/sendText/sendEnter) — context the driver's
 * `postLaunch(tmuxName)` / `awaitReady(tmuxName, sessionId)` slots do not
 * receive. The launch command calls them on the derive (codex) path, mirroring
 * how `awaitSessionStart` owns claude's proof-of-life wait.
 *
 * Both are best-effort: a worker that never shows the gate / composer still
 * "launches" (codex's `--dangerously-bypass-hook-trust` can race the gate, and
 * codex emits no session_start until the first prompt, so there is no hard
 * proof-of-life signal at launch — the meta self-registers on the first send).
 */

import type { CommandContext } from './context.js';

const sleep = (ms: number): Promise<void> =>
  new Promise((r) => setTimeout(r, ms));

/** Bash literals from drivers/codex.sh. */
const DEFAULT_TRUST_TIMEOUT_MS = 8_000;
const DEFAULT_TRUST_POLL_MS = 250;
/** The gap between sending '2' and Enter (bash `sleep 0.3`). */
const DEFAULT_TRUST_SETTLE_MS = 300;
const DEFAULT_READY_TIMEOUT_MS = 20_000;
const DEFAULT_READY_POLL_MS = 500;

/**
 * The idle composer: the glyph (U+203A) followed by its placeholder. The glyph
 * alone is not enough — codex's startup modals (model migration, rate-limit
 * model nudge) use the same glyph as their selection cursor.
 */
const COMPOSER_READY = /›\s+Ask Codex/;

/** Any of the trust-gate prompts codex shows for un-reviewed hooks. */
const TRUST_GATE = /hooks need review|trust all and continue|trust all/i;

export interface CodexTrustGateOpts {
  /** Trust-gate window in ms (bash: 8s). */
  timeoutMs?: number;
  /** Poll interval in ms (bash: 250ms). */
  pollMs?: number;
  /** Delay between sending '2' and Enter in ms (bash: 300ms). */
  settleMs?: number;
}

export interface CodexComposerOpts {
  /** Composer-ready window in ms (bash: 20s). */
  timeoutMs?: number;
  /** Poll interval in ms (bash: 500ms). */
  pollMs?: number;
}

/**
 * Dismiss codex's "Hooks need review" trust gate. Poll the pane; when the gate
 * text appears, choose option 2 ("Trust all and continue") by sending '2', a
 * short settle, then Enter. Best-effort: if the gate never appears within the
 * window, return having done nothing.
 */
export async function dismissCodexTrustGate(
  ctx: CommandContext,
  tmuxName: string,
  opts: CodexTrustGateOpts = {},
): Promise<void> {
  const timeoutMs = opts.timeoutMs ?? DEFAULT_TRUST_TIMEOUT_MS;
  const pollMs = opts.pollMs ?? DEFAULT_TRUST_POLL_MS;
  const settleMs = opts.settleMs ?? DEFAULT_TRUST_SETTLE_MS;

  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const pane = await capture(ctx, tmuxName);
    if (TRUST_GATE.test(pane)) {
      await ctx.tmux.sendText(tmuxName, '2');
      await sleep(settleMs);
      await ctx.tmux.sendEnter(tmuxName);
      return;
    }
    await sleep(pollMs);
  }
}

/**
 * Block until codex's composer is ready (the idle composer line `› Ask Codex`
 * is visible; the bare glyph also appears as a modal cursor), or
 * settle after the window. derive readiness has no hard signal — codex's
 * session_start fires at the first prompt, not at boot — so this is best-effort:
 * it returns success on timeout, and the first send re-confirms via the hook's
 * meta self-registration.
 */
export async function awaitComposerReady(
  ctx: CommandContext,
  tmuxName: string,
  opts: CodexComposerOpts = {},
): Promise<void> {
  const timeoutMs = opts.timeoutMs ?? DEFAULT_READY_TIMEOUT_MS;
  const pollMs = opts.pollMs ?? DEFAULT_READY_POLL_MS;

  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const pane = await capture(ctx, tmuxName);
    if (COMPOSER_READY.test(pane)) return;
    await sleep(pollMs);
  }
}

/** Capture the pane, treating a capture failure as an empty pane (best-effort). */
async function capture(ctx: CommandContext, tmuxName: string): Promise<string> {
  try {
    return await ctx.tmux.capturePane(tmuxName);
  } catch {
    return '';
  }
}
