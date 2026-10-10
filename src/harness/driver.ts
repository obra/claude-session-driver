/**
 * The harness-driver abstraction: the load-bearing seam that lets one CLI drive
 * Claude, Codex, and Pi workers. Each harness implements this same shape; the
 * launch/read commands talk only to the interface (see the csd multiharness
 * design spec §6).
 *
 * `launchArgv` is harness-specific. `prepare`/`postLaunch`/`awaitReady` are the
 * per-harness hooks the launch command orchestrates around (codex writes a
 * CODEX_HOME config in `prepare`; a harness with a trust gate dismisses it in
 * `postLaunch`). The transcript seam is split: `transcriptPath` locates the
 * JSONL, `parseTurn` does the harness-specific parse into the shared
 * `NormalizedTurn`.
 */

import type { NormalizedTurn } from '../core/transcript.js';

/**
 * How a worker is launched:
 * - `launch`: a fresh session (claude: `--session-id <sid>`).
 * - `adopt`: re-attach to an existing session after a reboot (claude:
 *   `--resume <sid>`).
 */
export type LaunchMode = 'launch' | 'adopt';

/** All supported harness identifiers. Extend here as new harnesses land. */
export type HarnessId = 'claude' | 'codex' | 'pi';

export interface HarnessDriver {
  /** Stable harness identifier. */
  id: HarnessId;

  /** How worker events reach the JSONL event sink. */
  controlPlane: 'hooks' | 'extension';

  /**
   * Whether the controller assigns the session id up front (`assign`) or the
   * harness mints its own id that the controller derives afterwards (`derive`).
   */
  idStrategy: 'assign' | 'derive';

  /**
   * Whether the worker's session id is known by the time `launch` returns. True
   * for claude (caller-assigned) and pi (registers synchronously at launch);
   * false for codex (registers only on its first prompt). Lets the launch panel
   * show the real id for harnesses that have it, vs a placeholder for codex.
   */
  registersIdAtLaunch: boolean;

  /** The keystrokes/command that quit the harness (e.g. `/exit`). */
  quitKeys: string;

  /**
   * Seconds `stop` waits for a `session_end` (or the pane to exit) after sending
   * the quit keys, before force-killing the tmux session. Harnesses that quit
   * cleanly (claude `/exit`, pi) keep a generous backstop; codex neither emits
   * `session_end` nor exits on its quit keys, so it uses a short grace to avoid
   * burning the full wait on every stop.
   */
  stopGraceSeconds: number;

  /** The binary to invoke (honours any per-harness override env var). */
  bin(): string;

  /**
   * The env pins for a worker's tmux session, derived from the controller's env.
   * Harness-specific: claude scrubs stale provider/IDE vars (issue #18); codex
   * pins `CODEX_HOME` to the per-worker home so the worker uses its own
   * config/auth/sessions dir; pi pins `PI_CODING_AGENT_DIR` + the
   * `CSD_WORKER_DIR`/`CSD_TMUX_NAME` its extension reads to self-register the
   * meta. The launch command expands the returned record into `-e KEY=VALUE`
   * pairs via `tmux.newSession`/`respawnPane`.
   *
   * `workerHome` is the per-worker home dir (claude: the controller HOME; codex:
   * the per-worker CODEX_HOME; pi: the per-worker PI_CODING_AGENT_DIR). It is
   * part of the signature because codex/pi's env genuinely depend on it; claude
   * ignores it.
   *
   * `tmuxName` is the worker's tmux window name. Pi's extension is the only
   * control plane that learns the session id at runtime (derive), so it must
   * read `CSD_TMUX_NAME` from the env to bake the right name into the meta it
   * self-registers; claude/codex carry the name via the pre-written meta / hook
   * args and ignore it.
   */
  workerEnv(
    workerHome: string,
    tmuxName: string,
    controllerEnv?: NodeJS.ProcessEnv,
  ): Record<string, string>;

  /**
   * The full program argv (binary FIRST, so it can be passed straight to
   * `tmux.newSession`) for the given launch `mode`. Harness extra-args (the
   * tokens after `--`) are NOT included here; the launch command appends them.
   *
   * `cwd`/`workerHome` are part of the uniform signature for harnesses that
   * embed them in their argv (e.g. a future codex --workdir); claude ignores
   * them (its tmux session is created in the right cwd by the launch command,
   * and HOME is set via env).
   */
  launchArgv(
    mode: LaunchMode,
    sessionId: string,
    cwd: string,
    pluginDir: string,
    workerHome: string,
  ): string[];

  /** Per-worker setup before tmux launches (e.g. write a CODEX_HOME config). */
  prepare(tmuxName: string, cwd: string, workerHome: string): Promise<void>;

  /** Post-launch fixup once the pane exists (e.g. dismiss a trust gate). */
  postLaunch(tmuxName: string): Promise<void>;

  /** Block until the worker is ready to accept a prompt. */
  awaitReady(tmuxName: string, sessionId: string): Promise<void>;

  /** Absolute path to the worker's transcript JSONL. */
  transcriptPath(sessionId: string, cwd: string, workerHome: string): string;

  /** Parse a transcript's JSONL into the shared normalized turn model. */
  parseTurn(transcript: string): NormalizedTurn;

  /**
   * False when the transcript visibly stops mid-turn, so converse should keep
   * reading it after the turn-end event rather than return a partial reply.
   */
  turnFinished(transcript: string): boolean;
}
