import { randomUUID } from 'node:crypto';
import { existsSync, mkdirSync, realpathSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { hasConsent } from '../core/consent.js';
import { readRawLines } from '../core/event-log.js';
import {
  ensureBackCompatSymlink,
  eventsPath,
  workerHomePath,
} from '../core/paths.js';
import { shellQuote } from '../core/shell.js';
import { isoSecondsUtc } from '../core/time.js';
import {
  resolveSession,
  writeHarnessMarker,
  writeMeta,
  writeShim,
} from '../core/worker-store.js';
import type { HarnessDriver } from '../harness/driver.js';
import { getDriver } from '../harness/registry.js';
import { awaitSessionStart } from './await-start.js';
import { awaitComposerReady, dismissCodexTrustGate } from './codex-launch.js';
import type { CommandContext, CommandResult } from './context.js';
import { awaitPiReady } from './pi-launch.js';

/** The shared bootstrap options launch and adopt both accept. */
export interface BootstrapOpts {
  /** Plugin root, passed to the harness via `--plugin-dir`. */
  pluginDir: string;
  /** Absolute path to the csd entry (dist/csd.cjs) baked into each worker shim. */
  csdEntry: string;
  /** The csd command path used in the reproduce line + consent message. */
  csdPath: string;
  /** awaitSessionStart timing overrides (tests pass tiny values). */
  startTimeoutMs?: number;
  pollMs?: number;
  /**
   * Codex (derive) launch-gate timing overrides (tests pass tiny values): the
   * trust-gate dismissal window and the composer-ready window. Unused on the
   * claude (assign) path.
   */
  codexTrustTimeoutMs?: number;
  codexReadyTimeoutMs?: number;
  codexTrustSettleMs?: number;
  /**
   * Pi (derive) launch-ready timing override (tests pass tiny values): the
   * status-bar/composer-ready window. Unused on the claude/codex paths.
   */
  piReadyTimeoutMs?: number;
}

export interface LaunchArgs {
  tmuxName: string;
  cwd: string;
  extraArgs: string[];
  /**
   * The harness to launch; the command resolves its own driver from this via
   * getDriver, which validates the id (the CLI also validates it at parse time).
   */
  harness: string;
}

/** The one-time-consent error, matching the bash text. */
export function consentError(csdPath: string): CommandResult {
  return {
    stderr: `Error: claude-session-driver requires one-time consent before launching workers.\nRun: ${csdPath} grant-consent`,
    code: 1,
  };
}

/**
 * Validate that cwd is an existing directory and resolve it to an absolute
 * realpath (bash `pwd -P`). Returns the resolved path, or a code-1 result.
 */
export function resolveCwd(cwd: string): string | CommandResult {
  if (!existsSync(cwd) || !statSync(cwd).isDirectory()) {
    return { stderr: `Error: cwd '${cwd}' does not exist`, code: 1 };
  }
  return realpathSync(cwd);
}

/** Render the status panel printed to stderr by launch/adopt. */
export function renderPanel(opts: {
  header: string;
  verb: string;
  tmuxName: string;
  sessionId: string;
  cwd: string;
  eventsFile: string;
  csdPath: string;
  invocation: string[];
}): string {
  const reproduceArgs = opts.invocation.map(shellQuote).join(' ');
  // The default csd path is the bundle (`dist/csd.cjs`) — a plain file with no
  // shebang and not +x, so a bare path isn't runnable. Prefix `node` for a JS
  // entry; a non-JS CSD_PATH wrapper override is used as-is (RE-2).
  const runnableCsd = /\.[cm]?js$/.test(opts.csdPath)
    ? `node ${shellQuote(opts.csdPath)}`
    : shellQuote(opts.csdPath);
  return [
    opts.header,
    `  tmux:       ${opts.tmuxName}`,
    `  session_id: ${opts.sessionId}`,
    `  cwd:        ${opts.cwd}`,
    `  events:     ${opts.eventsFile}`,
    `  reproduce: ${runnableCsd} ${opts.verb} ${reproduceArgs}`,
  ].join('\n');
}

/**
 * The per-worker home dir for a derive harness (codex's CODEX_HOME). Deterministic
 * from tmux_name so it can be re-derived without persisted state. Each worker gets
 * its own config/auth/sessions dir under `<workerDir>/homes/<tmuxName>` — the same
 * path `removeWorker` cleans up on stop (single source of truth in `paths.ts`).
 */
export function deriveWorkerHome(workerDir: string, tmuxName: string): string {
  return workerHomePath(workerDir, tmuxName);
}

/**
 * Launch a fresh worker. Parity port of bash `cmd_launch` (csd PR #21).
 *
 * The harness is chosen here, so launch resolves its OWN driver from `harness`
 * (ignoring `ctx.driver`). Two id strategies branch after the shared setup
 * (cwd validation, consent, collision, dir setup):
 *
 * - `assign` (claude): csd generates the session id, pre-writes the meta keyed
 *   by it (so the SessionStart hook can record events), and proof-of-life is a
 *   `session_start` event (orchestrated by `awaitSessionStart`).
 * - `derive` (codex): codex mints its OWN id at the first prompt, so csd does
 *   NOT generate an id or pre-write a meta — instead it writes a sidecar
 *   `.harness` marker (so per-worker commands resolve the codex driver during
 *   the pre-registration window) and the producer self-registers the meta on
 *   the first prompt. There is no session_start at boot, so "proof-of-life" is
 *   best-effort: dismiss the trust gate, then wait for the composer to be ready.
 */
export async function cmdLaunch(
  ctx: CommandContext,
  args: LaunchArgs,
  opts: BootstrapOpts,
): Promise<CommandResult> {
  const { tmuxName, extraArgs } = args;
  const driver = getDriver(args.harness);

  const resolved = resolveCwd(args.cwd);
  if (typeof resolved !== 'string') return resolved;
  const cwd = resolved;

  if (!hasConsent(ctx.home)) return consentError(opts.csdPath);

  if (await ctx.tmux.hasSession(tmuxName)) {
    return {
      stderr: `Error: tmux session '${tmuxName}' already exists`,
      code: 1,
    };
  }

  // Worker dir + bin dir must exist before writing meta/shim.
  mkdirSync(ctx.workerDir, { recursive: true });
  mkdirSync(join(ctx.workerDir, 'bin'), { recursive: true });
  ensureBackCompatSymlink(ctx.workerDir);

  const invocation =
    extraArgs.length > 0
      ? [tmuxName, cwd, '--', ...extraArgs]
      : [tmuxName, cwd];

  return driver.idStrategy === 'derive'
    ? launchDerive(ctx, { driver, tmuxName, cwd, extraArgs, invocation }, opts)
    : launchAssign(ctx, { driver, tmuxName, cwd, extraArgs, invocation }, opts);
}

interface LaunchInner {
  driver: HarnessDriver;
  tmuxName: string;
  cwd: string;
  extraArgs: string[];
  invocation: string[];
}

/**
 * The assign-id launch (claude): generate the session id, pre-write the meta,
 * start tmux, await `session_start` proof-of-life, write the shim. The driver's
 * worker home is the controller HOME.
 */
async function launchAssign(
  ctx: CommandContext,
  { driver, tmuxName, cwd, extraArgs, invocation }: LaunchInner,
  opts: BootstrapOpts,
): Promise<CommandResult> {
  const sessionId = randomUUID();

  // Pre-write the meta keyed by sessionId so the SessionStart hook can record
  // events the moment the worker starts. The hook only appends events once a
  // meta exists, so awaiting session_start would deadlock if the meta were
  // written after the worker (and the timeout teardown removes it).
  writeMeta(ctx.workerDir, {
    tmux_name: tmuxName,
    session_id: sessionId,
    cwd,
    harness: driver.id,
    started_at: isoSecondsUtc(),
    invocation,
  });

  const env = driver.workerEnv(ctx.home, tmuxName, process.env);
  await driver.prepare(tmuxName, cwd, ctx.home);

  const argv = [
    ...driver.launchArgv('launch', sessionId, cwd, opts.pluginDir, ctx.home),
    ...extraArgs,
  ];
  // Capture the attempt boundary before tmux starts. The SessionStart hook can
  // append synchronously during newSession, so taking this baseline afterward
  // would race an extremely fast worker.
  const eventLineBaseline = readRawLines(
    eventsPath(ctx.workerDir, sessionId),
  ).length;
  await ctx.tmux.newSession(tmuxName, cwd, env, argv);

  await driver.postLaunch(tmuxName);

  const proof = await awaitSessionStart(ctx, tmuxName, sessionId, {
    cwd,
    csdPath: opts.csdPath,
    afterLine: eventLineBaseline,
    startTimeoutMs: opts.startTimeoutMs,
    pollMs: opts.pollMs,
  });
  if (!proof.started) {
    return { stderr: proof.failureMessage, code: 1 };
  }

  const shim = writeShim(ctx.workerDir, tmuxName, opts.csdEntry);
  const panel = renderPanel({
    header: 'Worker launched.',
    verb: 'launch',
    tmuxName,
    sessionId,
    cwd,
    eventsFile: eventsPath(ctx.workerDir, sessionId),
    csdPath: opts.csdPath,
    invocation,
  });

  return { stdout: shim, stderr: panel, code: 0 };
}

/**
 * The derive-id launch (codex, pi): NO session id, NO pre-written meta. Write
 * the sidecar `.harness` marker, prepare the per-worker home, start tmux, write
 * the shim. The meta self-registers on the first prompt; the session id / events
 * file are unknown at launch (shown as placeholders in the panel).
 *
 * Codex additionally runs the trust-gate dismissal and composer-ready wait. Pi
 * has no trust gate, so it runs only a light status-bar/composer-ready wait
 * (awaitPiReady) — enough to let the TUI come up before the first send; the meta
 * still self-registers when pi fires its first event.
 */
async function launchDerive(
  ctx: CommandContext,
  { driver, tmuxName, cwd, extraArgs, invocation }: LaunchInner,
  opts: BootstrapOpts,
): Promise<CommandResult> {
  // Sidecar marker so per-worker commands load the codex or pi driver during
  // the pre-registration window (before the extension self-registers the meta).
  writeHarnessMarker(ctx.workerDir, tmuxName, driver.id);

  const workerHome = deriveWorkerHome(ctx.workerDir, tmuxName);
  const env = driver.workerEnv(workerHome, tmuxName, process.env);
  await driver.prepare(tmuxName, cwd, workerHome);

  const argv = [
    ...driver.launchArgv('launch', '', cwd, opts.pluginDir, workerHome),
    ...extraArgs,
  ];
  await ctx.tmux.newSession(tmuxName, cwd, env, argv);

  // Per-harness launch-ready waits are handled here in the command layer (they
  // need the tmux pane, which driver.postLaunch/awaitReady do not receive):
  //   - codex: dismiss the "Hooks need review" trust gate, then wait for the
  //     composer glyph.
  //   - pi: no trust gate, so just a light status-bar/composer-ready wait so the
  //     TUI is up before the first send (the meta self-registers on first event).
  if (driver.id === 'codex') {
    await dismissCodexTrustGate(ctx, tmuxName, {
      timeoutMs: opts.codexTrustTimeoutMs,
      settleMs: opts.codexTrustSettleMs,
      pollMs: opts.pollMs,
    });
    await awaitComposerReady(ctx, tmuxName, {
      timeoutMs: opts.codexReadyTimeoutMs,
      pollMs: opts.pollMs,
    });
  } else if (driver.id === 'pi') {
    await awaitPiReady(ctx, tmuxName, {
      timeoutMs: opts.piReadyTimeoutMs,
      pollMs: opts.pollMs,
    });
  }

  const shim = writeShim(ctx.workerDir, tmuxName, opts.csdEntry);
  // A launch-registering derive harness (pi) already has its real id by now; show
  // it. Codex registers only on its first prompt, so it gets the placeholder
  // (N-2 / RE-5b — the old "on first prompt" was wrong for pi).
  const registeredSid = driver.registersIdAtLaunch
    ? resolveSession(ctx.workerDir, tmuxName)
    : null;
  const panel = renderPanel({
    header: 'Worker launched.',
    verb: 'launch',
    tmuxName,
    sessionId:
      registeredSid ?? '(derive — minted by the harness on registration)',
    cwd,
    eventsFile: registeredSid
      ? eventsPath(ctx.workerDir, registeredSid)
      : '(available after the worker registers)',
    csdPath: opts.csdPath,
    invocation,
  });

  return { stdout: shim, stderr: panel, code: 0 };
}
