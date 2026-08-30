/**
 * End-to-end integration: the bundled csd CLI + REAL tmux, driving a `fake-pi`
 * test double instead of the real pi coding agent, through the DERIVE control-
 * plane flow (`--harness pi`).
 *
 * This proves the full launch -> status -> read-turn -> send -> stop flow works
 * against the actual shipped bundle and a live tmux server for pi, where:
 *   - csd assigns NO session id and writes NO meta at launch (pi mints its own
 *     id; the extension self-registers the meta on the boot turn),
 *   - launch runs a light status-bar/composer-ready wait (awaitPiReady) instead
 *     of a session_start proof-of-life — pi has no trust gate,
 *   - the per-worker driver is resolved from the self-registered meta so
 *     send/read-turn/status drive the pi transcript + derive send paths.
 *
 * Pi's control plane is a native EXTENSION, not a hook command we can invoke with
 * baked args (the way fake-codex shells out to emit-event.cjs). A fake binary
 * cannot host our extension and fire genuine `pi.on` events, so fake-pi SIMULATES
 * what pi + the extension TOGETHER produce: it self-registers `<sid>.meta` and
 * writes the WorkerEvents + a pi session transcript DIRECTLY (standing in for the
 * extension's output). Everything else is real: real `node dist/csd.cjs`, real
 * tmux. The test then drives the REAL csd bundle against that fake-produced state.
 *
 * The fake-pi reads CSD_WORKER_DIR + CSD_TMUX_NAME from the worker tmux env (the
 * pi driver pins them) and `--session-dir` from its argv (the pi driver passes
 * `--session-dir <home>/sessions`), so unlike fake-claude it needs no per-test
 * wrapper to learn paths. We point CSD_PI_BIN straight at the committed fixture.
 *
 * Requires a real `tmux` on PATH; the suite skips itself cleanly when absent.
 */

import { execFile, execFileSync } from 'node:child_process';
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
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
const piExtension = join(dist, 'pi-extension.mjs');
const fakePi = join(repoRoot, 'tests', 'fixtures', 'fake-pi');

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
  process.stderr.write('pi-flow integration: SKIPPED (no `tmux` on PATH)\n');
}

let uniqueCounter = 0;
function uniqueName(): string {
  uniqueCounter += 1;
  return `csd-pi-${process.pid}-${uniqueCounter}-${Math.random().toString(36).slice(2, 8)}`;
}

describe.skipIf(!HAS_TMUX)('pi flow e2e (real tmux + bundled csd)', () => {
  let workerDir: string;
  let home: string;
  let cwd: string;
  let tmuxName: string;

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
    workerDir = mkdtempSync(join(tmpdir(), 'csd-pi-wd-'));
    home = mkdtempSync(join(tmpdir(), 'csd-pi-home-'));
    cwd = mkdtempSync(join(tmpdir(), 'csd-pi-cwd-'));
    tmuxName = uniqueName();

    mkdirSync(join(home, '.claude'), { recursive: true });
    // Pre-grant consent: launch refuses to run without it.
    writeFileSync(join(home, '.claude', '.claude-session-driver-consent'), '');
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

  /**
   * Launch a pi worker via the bundled CLI; returns the printed shim path.
   * CSD_PI_BIN points at the fake; CSD_PI_EXTENSION_PATH points at the real
   * bundled extension (the launch command bakes it into the `-e` flag — the fake
   * ignores it, but the path must be the real shipped one for fidelity).
   */
  async function launch(): Promise<{ stdout: string; stderr: string }> {
    const result = await runWithEnv(
      ['node', csdEntry, 'launch', tmuxName, cwd, '--harness', 'pi'],
      {
        CSD_PI_BIN: fakePi,
        CSD_PI_EXTENSION_PATH: piExtension,
        CSD_WORKER_DIR: workerDir,
        HOME: home,
        CLAUDE_PLUGIN_ROOT: repoRoot,
      },
    );
    expect(result.code, `launch failed:\n${result.stderr}`).toBe(0);
    return { stdout: result.stdout.trim(), stderr: result.stderr };
  }

  /** Poll until the worker's meta self-registers (pi's boot turn), or fail. */
  async function awaitRegistered(timeoutMs = 20_000): Promise<string> {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      const sid = (await worker('session-id')).stdout.trim();
      if (sid.length > 0) return sid;
      await sleep(200);
    }
    const panes = capturePane(tmuxName);
    throw new Error(
      `worker never self-registered within ${timeoutMs}ms.\npane:\n${panes}`,
    );
  }

  it('launches a pi worker: derive panel + executable shim, NO meta at launch', async () => {
    const { stdout: shim, stderr: panel } = await launch();

    // stdout is the deterministic shim path, and the file is executable.
    expect(shim).toBe(join(workerDir, 'bin', tmuxName));
    expect(existsSync(shim)).toBe(true);
    expect(statSync(shim).mode & 0o100).toBeTruthy();

    // pi registers its id at launch, so the panel shows the real id + events path
    // (not the derive placeholder) (N-2).
    expect(panel).toMatch(/session_id: [0-9a-f][0-9a-f-]{7,}/);
    expect(panel).toContain('.events.jsonl');
    expect(panel).not.toContain('(derive');

    // The tmux session is live and the sidecar harness marker exists.
    expect(hasSession(tmuxName)).toBe(true);
    expect(readFileSync(join(workerDir, `${tmuxName}.harness`), 'utf8')).toBe(
      'pi',
    );

    await worker('stop');
  });

  it('the boot turn self-registers the meta; status + read-turn resolve via the pi driver', async () => {
    await launch();

    // The fake fires a boot turn (session_start -> user_prompt_submit -> stop)
    // and self-registers <sid>.meta. Once that lands, the worker resolves by
    // tmux name.
    const sid = await awaitRegistered();
    expect(sid.length).toBeGreaterThan(0);

    // A real <sid>.meta was self-registered (csd wrote none at launch).
    const metas = readdirSync(workerDir).filter((f) => f.endsWith('.meta'));
    expect(metas).toEqual([`${sid}.meta`]);

    // status resolves (pi driver, by tmux name -> sid). The boot turn ended
    // with stop, so the worker is idle.
    const status = await worker('status');
    expect(status.code, status.stderr).toBe(0);
    expect(status.stdout.trim()).toBe('idle');

    // read-turn renders the pi transcript (driver resolved from meta.harness).
    const turn = await worker('read-turn');
    expect(turn.code, turn.stderr).toBe(0);
    expect(turn.stdout).toContain('FAKE_PI_DONE');

    await worker('stop');
  });

  it('send confirms a pasted prompt over real tmux (derive send path)', async () => {
    await launch();
    const sid = await awaitRegistered();
    const eventsFile = join(workerDir, `${sid}.events.jsonl`);

    // send pastes the prompt and blocks until the worker confirms submission
    // via a user_prompt_submit event (issue #20). The fake emits it on stdin.
    const sent = await runWithEnv(
      ['node', csdEntry, '--worker', tmuxName, 'send', 'do the needful'],
      { CSD_WORKER_DIR: workerDir, HOME: home, CSD_SUBMIT_TIMEOUT: '15' },
    );
    expect(sent.code, `send failed:\n${sent.stderr}`).toBe(0);

    // The worker emitted user_prompt_submit (its ground-truth submit signal).
    const events = readFileSync(eventsFile, 'utf8');
    expect(events).toContain('"event":"user_prompt_submit"');

    await worker('stop');
  });

  it('stop kills the session and removes the worker state (meta/events/shim/marker)', async () => {
    await launch();
    const sid = await awaitRegistered();

    const metaFile = join(workerDir, `${sid}.meta`);
    const eventsFile = join(workerDir, `${sid}.events.jsonl`);
    const shim = join(workerDir, 'bin', tmuxName);
    const marker = join(workerDir, `${tmuxName}.harness`);
    expect(existsSync(metaFile)).toBe(true);
    expect(existsSync(shim)).toBe(true);

    const stopped = await worker('stop');
    expect(stopped.code, stopped.stderr).toBe(0);

    // tmux session is gone and every worker file was removed.
    expect(hasSession(tmuxName)).toBe(false);
    expect(existsSync(metaFile)).toBe(false);
    expect(existsSync(eventsFile)).toBe(false);
    expect(existsSync(shim)).toBe(false);
    expect(existsSync(marker)).toBe(false);
  });
});

// --- helpers -------------------------------------------------------------

const sleep = (ms: number): Promise<void> =>
  new Promise((r) => setTimeout(r, ms));

/**
 * Run a command with extra env merged over process.env, mirroring the proc
 * `run` contract (resolves with {stdout, stderr, code}, never rejects).
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

function capturePane(name: string): string {
  try {
    return execFileSync('tmux', ['capture-pane', '-t', name, '-p'], {
      encoding: 'utf8',
    });
  } catch {
    return '(pane capture failed)';
  }
}
