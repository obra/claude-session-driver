import {
  existsSync,
  mkdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { join } from 'node:path';
import { hasConsent } from '../core/consent.js';
import { readRawLines } from '../core/event-log.js';
import {
  ensureBackCompatSymlink,
  eventsPath,
  metaPath,
  shimPath,
} from '../core/paths.js';
import { isoSecondsUtc } from '../core/time.js';
import {
  readHarnessMarker,
  writeMeta,
  writeShim,
} from '../core/worker-store.js';
import { getDriver } from '../harness/registry.js';
import { awaitSessionStart } from './await-start.js';
import type { CommandContext, CommandResult } from './context.js';
import {
  type BootstrapOpts,
  consentError,
  renderPanel,
  resolveCwd,
} from './launch.js';

/** Claude session ids are UUID-ish: hex + dashes (bash csd:818). */
const CLAUDE_SESSION_ID = /^[0-9a-fA-F][0-9a-fA-F-]{7,}$/;

export interface AdoptArgs {
  tmuxName: string;
  cwd: string;
  /** The existing Claude session id to resume. */
  sessionId: string;
  extraArgs: string[];
}

interface AdoptAttemptSnapshot {
  tmuxExisted: boolean;
  metaContents: Buffer | null;
  eventsExisted: boolean;
  shimExisted: boolean;
}

async function snapshotAdoptState(
  ctx: CommandContext,
  tmuxName: string,
  sessionId: string,
): Promise<AdoptAttemptSnapshot> {
  const metaFile = metaPath(ctx.workerDir, sessionId);
  return {
    tmuxExisted: await ctx.tmux.hasSession(tmuxName),
    metaContents: existsSync(metaFile) ? readFileSync(metaFile) : null,
    eventsExisted: existsSync(eventsPath(ctx.workerDir, sessionId)),
    shimExisted: existsSync(shimPath(ctx.workerDir, tmuxName)),
  };
}

async function rollbackFailedAdopt(
  ctx: CommandContext,
  tmuxName: string,
  sessionId: string,
  snapshot: AdoptAttemptSnapshot,
): Promise<void> {
  try {
    if (!snapshot.tmuxExisted) {
      await ctx.tmux.killSession(tmuxName);
    }
  } finally {
    const metaFile = metaPath(ctx.workerDir, sessionId);
    if (snapshot.metaContents === null) {
      rmSync(metaFile, { force: true });
    } else {
      writeFileSync(metaFile, snapshot.metaContents);
    }
    if (!snapshot.eventsExisted) {
      rmSync(eventsPath(ctx.workerDir, sessionId), { force: true });
    }
    if (!snapshot.shimExisted) {
      rmSync(shimPath(ctx.workerDir, tmuxName), { force: true });
    }
  }
}

/**
 * Re-attach to an existing Claude session after a reboot. Parity port of bash
 * `cmd_adopt` (csd:791-905). Claude-only: there is no `--harness` flag, so the
 * driver is always claude.
 *
 * `claude --resume <id>` preserves the session id, so the worker's runtime
 * session_id equals the supplied id. The meta is pre-written keyed by that id
 * BEFORE claude starts, because the SessionStart hook only records events once a
 * meta exists for the session. If a tmux session already exists (e.g. restored
 * by tmux-resurrect), its pane is respawned in place to preserve the window
 * layout; otherwise a new detached session is opened.
 *
 * The proof-of-life wait mirrors launch, but rollback is ownership-aware:
 * inherited tmux and files survive a failed resume attempt.
 */
export async function cmdAdopt(
  ctx: CommandContext,
  args: AdoptArgs,
  opts: BootstrapOpts,
): Promise<CommandResult> {
  const { tmuxName, sessionId, extraArgs } = args;
  const driver = getDriver('claude');

  const resolved = resolveCwd(args.cwd);
  if (typeof resolved !== 'string') return resolved;
  const cwd = resolved;

  if (!CLAUDE_SESSION_ID.test(sessionId)) {
    return {
      stderr: `Error: '${sessionId}' does not look like a Claude session id`,
      code: 1,
    };
  }

  if (!hasConsent(ctx.home)) return consentError(opts.csdPath);

  // adopt is claude-only. A codex/pi worker of this tmux-name leaves a `.harness`
  // sidecar; refuse rather than respawn its pane as `claude --resume <id>`, which
  // would rewrite its meta and destroy it. Claude workers leave no sidecar, so
  // re-adopting one is unaffected.
  const existingHarness = readHarnessMarker(ctx.workerDir, tmuxName);
  if (existingHarness !== null && existingHarness !== 'claude') {
    return {
      stderr: `Error: '${tmuxName}' is a ${existingHarness} worker; adopt is claude-only (codex/pi mint their own ids and offer no resume-by-id). Stop it first, then relaunch.`,
      code: 1,
    };
  }

  // A bad/typo'd session id otherwise burns the full 30s session_start wait, then
  // returns a generic "failed to start". The transcript must exist to resume it,
  // so fail fast and name the id (N-1).
  const transcript = driver.transcriptPath(sessionId, cwd, ctx.home);
  if (!existsSync(transcript)) {
    return {
      stderr: `Error: no transcript found for session '${sessionId}' under ${cwd} (expected ${transcript}); it cannot be adopted — check the session id and cwd.`,
      code: 1,
    };
  }

  // Snapshot ownership before writing meta or starting/respawning tmux. Adopt
  // can inherit all four resources from an earlier worker and must not delete
  // them merely because this resume attempt fails proof-of-life.
  const preexisting = await snapshotAdoptState(ctx, tmuxName, sessionId);

  mkdirSync(ctx.workerDir, { recursive: true });
  mkdirSync(join(ctx.workerDir, 'bin'), { recursive: true });
  ensureBackCompatSymlink(ctx.workerDir);

  const invocation =
    extraArgs.length > 0
      ? [tmuxName, cwd, sessionId, '--', ...extraArgs]
      : [tmuxName, cwd, sessionId];

  // Pre-write the meta keyed by sessionId so the SessionStart hook can record
  // events the moment claude starts.
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
    ...driver.launchArgv('adopt', sessionId, cwd, opts.pluginDir, ctx.home),
    ...extraArgs,
  ];

  // A resumed session id can already have an event log from its prior worker.
  // Capture the attempt boundary before either tmux start path so even a hook
  // that writes session_start synchronously is visible to awaitSessionStart.
  const eventLineBaseline = readRawLines(
    eventsPath(ctx.workerDir, sessionId),
  ).length;

  let mode: string;
  if (preexisting.tmuxExisted) {
    mode = 'respawned existing pane';
    await ctx.tmux.respawnPane(tmuxName, cwd, env, argv);
  } else {
    mode = 'opened new pane';
    await ctx.tmux.newSession(tmuxName, cwd, env, argv);
  }

  await driver.postLaunch(tmuxName);

  const proof = await awaitSessionStart(ctx, tmuxName, sessionId, {
    cwd,
    csdPath: opts.csdPath,
    afterLine: eventLineBaseline,
    startTimeoutMs: opts.startTimeoutMs,
    pollMs: opts.pollMs,
  });
  if (!proof.started) {
    await rollbackFailedAdopt(ctx, tmuxName, sessionId, preexisting);
    return { stderr: proof.failureMessage, code: 1 };
  }

  const shim = writeShim(ctx.workerDir, tmuxName, opts.csdEntry);
  const panel = renderPanel({
    header: `Worker adopted (${mode}).`,
    verb: 'adopt',
    tmuxName,
    sessionId,
    cwd,
    eventsFile: eventsPath(ctx.workerDir, sessionId),
    csdPath: opts.csdPath,
    invocation,
  });

  return { stdout: shim, stderr: panel, code: 0 };
}
