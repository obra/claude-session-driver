/**
 * The Pi (@earendil-works/pi-coding-agent) harness driver. Pi is the third
 * harness; its control plane is a native TypeScript EXTENSION (the bundled
 * `dist/pi-extension.mjs`, loaded via `pi -e <path>`), NOT lifecycle hooks. The
 * verified contract this driver implements is the C1 comment block atop
 * `src/pi-extension/index.ts`.
 *
 * Pi mints its OWN session id (idStrategy `derive`; there is NO `--session-id`
 * flag), so the extension self-registers `<sid>.meta` on its first event — and
 * `transcriptPath` reads `transcript_path` back from that meta, exactly like the
 * codex driver. The extension reads `CSD_WORKER_DIR` + `CSD_TMUX_NAME` from the
 * worker env (C2's contract), so `workerEnv` pins those plus
 * `PI_CODING_AGENT_DIR` (the per-worker agent dir holding auth/sessions).
 *
 * `prepare` is LIGHTER than codex's: there is no per-worker config file to write
 * because the extension is registered by the `-e` launch flag and the rest of
 * pi's wiring rides in the env. `prepare` only ensures the worker home exists
 * and stages the operator's `~/.pi/agent/auth.json` (and `models.json` /
 * `settings.json` if present) so the worker authenticates as the operator.
 *
 * `postLaunch` (any post-launch fixup) and `awaitReady` (pi's composer/prompt
 * ready signal) need the tmux pane, which this interface does not hand the
 * driver; they are documented no-ops here and the launch command (C4) wires pi's
 * launch-time await, analogous to codex's trust-gate/composer dance.
 */

import { copyFileSync, existsSync, mkdirSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { workerDir } from '../core/paths.js';
import { type NormalizedTurn, parsePiTurn } from '../core/transcript.js';
import { readMeta } from '../core/worker-store.js';
import type { HarnessDriver, LaunchMode } from './driver.js';

/** Files copied from the operator's pi agent dir into a worker's home, if present. */
const PI_AUTH_FILES = ['auth.json', 'models.json', 'settings.json'] as const;

/**
 * The operator's pi agent dir: `PI_CODING_AGENT_DIR` if set (verified env
 * override), else `~/.pi/agent` (the verified default; `getAgentDir()`).
 */
function operatorAgentDir(): string {
  return process.env.PI_CODING_AGENT_DIR ?? join(homedir(), '.pi', 'agent');
}

/**
 * The absolute path to the bundled `pi-extension.mjs`. Injectable via
 * `CSD_PI_EXTENSION_PATH` (tests set it); otherwise it sits next to the running
 * `csd.cjs` bundle (tsup emits both into `dist/`), so `__dirname` is `dist/`.
 */
function piExtensionPath(): string {
  const override = process.env.CSD_PI_EXTENSION_PATH;
  if (override) return override;
  return join(__dirname, 'pi-extension.mjs');
}

/**
 * The per-worker tmux env. Pi reads its auth/sessions from PI_CODING_AGENT_DIR;
 * the csd extension (C2) reads CSD_WORKER_DIR (the events/meta sink) and
 * CSD_TMUX_NAME (baked into the self-registered meta) from this env.
 */
export function piWorkerEnv(
  workerHome: string,
  tmuxName: string,
): Record<string, string> {
  return {
    PI_CODING_AGENT_DIR: workerHome,
    CSD_WORKER_DIR: workerDir(),
    CSD_TMUX_NAME: tmuxName,
  };
}

export const pi: HarnessDriver = {
  id: 'pi',
  controlPlane: 'extension',
  idStrategy: 'derive',
  registersIdAtLaunch: true,
  quitKeys: '/quit',
  stopGraceSeconds: 10,

  bin(): string {
    return process.env.CSD_PI_BIN ?? 'pi';
  },

  // Pi's env genuinely depends on BOTH workerHome (PI_CODING_AGENT_DIR) and
  // tmuxName (CSD_TMUX_NAME the extension self-registers the meta with).
  workerEnv(
    workerHome: string,
    tmuxName: string,
    _controllerEnv: NodeJS.ProcessEnv = process.env,
  ): Record<string, string> {
    return piWorkerEnv(workerHome, tmuxName);
  },

  // Pi ignores mode/sid (derive — it mints its own id, no --session-id flag) and
  // cwd (its tmux session is created in the right cwd by the launch command).
  // The session dir is per-worker (isolated under the worker home); the
  // extension is registered with the `-e` flag. `--model`/`--provider` are
  // OMITTED unless CSD_PI_MODEL is set, so pi falls back to its configured
  // default model; --provider only rides along when a model is also chosen.
  launchArgv(
    _mode: LaunchMode,
    _sessionId: string,
    _cwd: string,
    _pluginDir: string,
    workerHome: string,
  ): string[] {
    const argv = [this.bin(), '--session-dir', join(workerHome, 'sessions')];
    const model = process.env.CSD_PI_MODEL;
    if (model) {
      argv.push('--model', model);
      const provider = process.env.CSD_PI_PROVIDER;
      if (provider) argv.push('--provider', provider);
    }
    argv.push('-e', piExtensionPath());
    return argv;
  },

  // Lighter than codex: no per-worker config file (the extension is registered
  // by the `-e` flag, the rest rides in the env). Just ensure the worker home
  // exists and stage the operator's pi credentials so the worker authenticates
  // as them. Best-effort: a missing operator file is skipped, never fatal.
  async prepare(
    _tmuxName: string,
    _cwd: string,
    workerHome: string,
  ): Promise<void> {
    mkdirSync(workerHome, { recursive: true });
    const agentDir = operatorAgentDir();
    for (const name of PI_AUTH_FILES) {
      const src = join(agentDir, name);
      if (existsSync(src)) {
        copyFileSync(src, join(workerHome, name));
      }
    }
  },

  // Any post-launch fixup needs the tmux pane, which this interface does not
  // pass the driver; pi's launch-time orchestration lives in the launch command
  // (C4). No-op here (mirrors codex).
  async postLaunch(_tmuxName: string): Promise<void> {},

  // Pi's composer/prompt ready signal also needs tmux; the real wait lives in
  // the launch command (C4). No-op here (mirrors codex).
  async awaitReady(_tmuxName: string, _sessionId: string): Promise<void> {},

  // Pi mints its own session id, so the transcript path is not derivable from
  // (cwd, home): the self-registering extension records it in `<sid>.meta`
  // (`transcript_path` = `getSessionFile()`). We read it back from the worker
  // dir's meta. Returns '' when the meta or field is absent (mirrors codex).
  transcriptPath(sessionId: string, _cwd: string, _workerHome: string): string {
    const meta = readMeta(workerDir(), sessionId);
    const path = meta?.transcript_path;
    return typeof path === 'string' ? path : '';
  },

  parseTurn(transcript: string): NormalizedTurn {
    return parsePiTurn(transcript);
  },

  // No mid-turn marker is checked for this harness.
  turnFinished(_transcript: string): boolean {
    return true;
  },
};
