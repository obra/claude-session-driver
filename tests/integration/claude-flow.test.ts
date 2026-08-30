/**
 * End-to-end integration: the bundled csd CLI + bundled hook + REAL tmux,
 * driving a `fake-claude` test double instead of the real Claude binary.
 *
 * This proves the full launch -> status -> read-turn -> send -> wait-for-turn
 * -> read-turn -> stop flow works against the actual shipped bundle and a live
 * tmux server. Everything except "claude" is real: real `node dist/csd.cjs`,
 * real `dist/emit-event.cjs` hook (invoked by the fake the way Claude would),
 * real tmux new-session / send-keys / has-session / kill-session.
 *
 * The fake-claude fixture (tests/fixtures/fake-claude) cannot learn the
 * per-test temp worker dir / HOME from a fresh tmux session (which inherits
 * only the scrubbed `-e` pins, not the launcher's env). A tiny per-test wrapper
 * bakes those paths in as env vars and execs the committed fixture, so the
 * fixture stays the single canonical, reviewable test double.
 *
 * Requires a real `tmux` on PATH; the suite skips itself cleanly when absent.
 */

import { execFile, execFileSync } from 'node:child_process';
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(here, '..', '..');
const dist = join(repoRoot, 'dist');
const csdEntry = join(dist, 'csd.cjs');
const fakeClaude = join(repoRoot, 'tests', 'fixtures', 'fake-claude');

/** True when a real tmux binary is on PATH (the suite needs one). */
function tmuxAvailable(): boolean {
  try {
    execFileSync('tmux', ['-V'], { stdio: 'ignore' });
    return true;
  } catch {
    return false;
  }
}

const HAS_TMUX = tmuxAvailable();
vi.setConfig({ testTimeout: 60_000 });
if (!HAS_TMUX) {
  // Surface the skip reason rather than silently green-lighting.
  process.stderr.write(
    'claude-flow integration: SKIPPED (no `tmux` on PATH)\n',
  );
}

let uniqueCounter = 0;
function uniqueName(): string {
  uniqueCounter += 1;
  return `csd-it-${process.pid}-${uniqueCounter}-${Math.random().toString(36).slice(2, 8)}`;
}

describe.skipIf(!HAS_TMUX)('claude flow e2e (real tmux + bundled csd)', () => {
  let workerDir: string;
  let home: string;
  let cwd: string;
  let tmuxName: string;
  let wrapper: string;

  /** Run the bundled CLI with the per-test worker dir + HOME pinned. */
  async function csd(args: string[]): Promise<{
    stdout: string;
    stderr: string;
    code: number;
  }> {
    return runWithEnv(['node', csdEntry, ...args], {
      CSD_WORKER_DIR: workerDir,
      HOME: home,
    });
  }

  /** Run a per-worker subcommand (shim-equivalent: `--worker <name>`). */
  async function worker(...args: string[]) {
    return csd(['--worker', tmuxName, ...args]);
  }

  beforeEach(() => {
    workerDir = mkdtempSync(join(tmpdir(), 'csd-it-wd-'));
    home = mkdtempSync(join(tmpdir(), 'csd-it-home-'));
    cwd = mkdtempSync(join(tmpdir(), 'csd-it-cwd-'));
    tmuxName = uniqueName();

    mkdirSync(join(home, '.claude'), { recursive: true });
    // Pre-grant consent: launch refuses to run without it.
    writeFileSync(join(home, '.claude', '.claude-session-driver-consent'), '');

    // Per-test wrapper bakes the temp paths the fixture needs (a fresh tmux
    // session won't inherit them) and execs the committed fake-claude.
    wrapper = join(workerDir, 'fake-claude-wrapper');
    writeFileSync(
      wrapper,
      [
        '#!/usr/bin/env bash',
        `export CSD_FAKE_WORKER_DIR=${shq(workerDir)}`,
        `export CSD_FAKE_HOME=${shq(home)}`,
        `export CSD_FAKE_DIST=${shq(dist)}`,
        `exec node ${shq(fakeClaude)} "$@"`,
        '',
      ].join('\n'),
    );
    chmodSync(wrapper, 0o755);
  });

  afterEach(() => {
    // Always tear down the tmux session, even if a test failed mid-flow.
    try {
      execFileSync('tmux', ['kill-session', '-t', tmuxName], {
        stdio: 'ignore',
      });
    } catch {
      // already gone — fine.
    }
    for (const dir of [workerDir, home, cwd]) {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  /** Launch a worker via the bundled CLI; returns the printed shim path. */
  async function launch(): Promise<string> {
    const result = await runWithEnv(
      ['node', csdEntry, 'launch', tmuxName, cwd],
      {
        CSD_CLAUDE_BIN: wrapper,
        CSD_WORKER_DIR: workerDir,
        HOME: home,
        CLAUDE_PLUGIN_ROOT: repoRoot,
      },
    );
    expect(result.code, `launch failed:\n${result.stderr}`).toBe(0);
    return result.stdout.trim();
  }

  it('launch starts a real worker: prints an executable shim and reaches idle', async () => {
    const shim = await launch();

    // stdout is the deterministic shim path, and the file is executable.
    expect(shim).toBe(join(workerDir, 'bin', tmuxName));
    expect(existsSync(shim)).toBe(true);
    expect(statSync(shim).mode & 0o100).toBeTruthy();

    // The tmux session is live.
    expect(hasSession(tmuxName)).toBe(true);

    // After session_start (the last event), status is idle.
    const status = await worker('status');
    expect(status.code).toBe(0);
    expect(status.stdout.trim()).toBe('idle');

    await worker('stop');
  });

  it('read-turn renders the fake transcript through the real bundle', async () => {
    await launch();

    const turn = await worker('read-turn');
    expect(turn.code, turn.stderr).toBe(0);
    expect(turn.stdout).toContain('**Prompt:** hello fake worker');
    expect(turn.stdout).toContain('fake worker ready');

    await worker('stop');
  });

  it('send -> wait-for-turn -> read-turn round-trips a prompt over real tmux', async () => {
    await launch();
    const sid = (await worker('session-id')).stdout.trim();
    const eventsFile = join(workerDir, `${sid}.events.jsonl`);
    const linesBefore = countLines(eventsFile);

    // send pastes the prompt and blocks until the worker confirms submission
    // via a user_prompt_submit event (issue #20). The fake emits it on stdin.
    const sent = await runWithEnv(
      ['node', csdEntry, '--worker', tmuxName, 'send', 'do the needful'],
      { CSD_WORKER_DIR: workerDir, HOME: home, CSD_SUBMIT_TIMEOUT: '15' },
    );
    expect(sent.code, `send failed:\n${sent.stderr}`).toBe(0);

    // The worker emitted user_prompt_submit since the send (its ground truth).
    const events = readFileSync(eventsFile, 'utf8');
    expect(events).toContain('"event":"user_prompt_submit"');

    // wait-for-turn returns the turn-end (stop) event emitted after our prompt.
    const waited = await runWithEnv(
      [
        'node',
        csdEntry,
        '--worker',
        tmuxName,
        'wait-for-turn',
        '--after-line',
        String(linesBefore),
        '20',
      ],
      { CSD_WORKER_DIR: workerDir, HOME: home },
    );
    expect(waited.code, `wait-for-turn failed:\n${waited.stderr}`).toBe(0);
    expect(waited.stdout).toContain('"event":"stop"');

    // read-turn now reflects the prompt the worker processed.
    const turn = await worker('read-turn');
    expect(turn.code, turn.stderr).toBe(0);
    expect(turn.stdout).toContain('**Prompt:** do the needful');
    expect(turn.stdout).toContain('echo: do the needful');

    await worker('stop');
  });

  it('stop kills the session and removes the worker state', async () => {
    await launch();
    const sid = (await worker('session-id')).stdout.trim();

    const metaFile = join(workerDir, `${sid}.meta`);
    const eventsFile = join(workerDir, `${sid}.events.jsonl`);
    const shim = join(workerDir, 'bin', tmuxName);
    expect(existsSync(metaFile)).toBe(true);
    expect(existsSync(shim)).toBe(true);

    const stopped = await worker('stop');
    expect(stopped.code, stopped.stderr).toBe(0);

    // tmux session is gone and every worker file was removed.
    expect(hasSession(tmuxName)).toBe(false);
    expect(existsSync(metaFile)).toBe(false);
    expect(existsSync(eventsFile)).toBe(false);
    expect(existsSync(shim)).toBe(false);
  });
});

// --- helpers -------------------------------------------------------------

/** Single-quote a path for the generated bash wrapper. */
function shq(s: string): string {
  return `'${s.replaceAll("'", "'\\''")}'`;
}

/**
 * Run a command with extra env merged over process.env, mirroring the proc
 * `run` contract (resolves with {stdout, stderr, code}, never rejects). Unlike
 * proc.run this takes an explicit env, so no global process.env mutation.
 */
function runWithEnv(
  cmd: string[],
  env: Record<string, string>,
): Promise<{ stdout: string; stderr: string; code: number }> {
  const [bin, ...args] = cmd as [string, ...string[]];
  return new Promise((resolve) => {
    execFile(
      bin,
      args,
      {
        encoding: 'utf8',
        maxBuffer: 10 * 1024 * 1024,
        env: { ...process.env, ...env },
      },
      (err, stdout, stderr) => {
        if (!err) {
          resolve({ stdout, stderr, code: 0 });
          return;
        }
        const errCode = (err as { code?: unknown }).code;
        const code = typeof errCode === 'number' ? errCode : 1;
        resolve({ stdout: stdout ?? '', stderr: stderr || String(err), code });
      },
    );
  });
}

function hasSession(name: string): boolean {
  try {
    execFileSync('tmux', ['has-session', '-t', name], { stdio: 'ignore' });
    return true;
  } catch {
    return false;
  }
}

function countLines(file: string): number {
  if (!existsSync(file)) return 0;
  return readFileSync(file, 'utf8')
    .split('\n')
    .filter((l) => l.length > 0).length;
}
