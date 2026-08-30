/**
 * End-to-end integration: the bundled csd CLI + bundled hook + REAL tmux,
 * driving a `fake-codex` test double instead of the real codex binary, through
 * the DERIVE control-plane flow (`--harness codex`).
 *
 * This proves the full launch -> status -> read-turn -> send -> stop flow works
 * against the actual shipped bundle and a live tmux server for codex, where:
 *   - csd assigns NO session id and writes NO meta at launch (codex mints its
 *     own id and the hook self-registers the meta on the boot turn),
 *   - launch dismisses the "Hooks need review" trust gate + waits for the
 *     composer glyph instead of a session_start proof-of-life,
 *   - the per-worker driver is resolved from the self-registered meta so
 *     send/read-turn/status drive the codex transcript + derive send paths.
 *
 * Everything except "codex" is real: real `node dist/csd.cjs`, real
 * `dist/emit-event.cjs` hook (invoked by the fake through a real shell, so the
 * shell-quoted baked hook args are re-parsed end to end), real tmux.
 *
 * The fake-codex reads its config from $CODEX_HOME (a tmux `-e` pin csd sets),
 * so unlike fake-claude it needs no per-test wrapper to learn paths. We still
 * point CSD_CODEX_BIN straight at the committed fixture.
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
const emitEvent = join(dist, 'emit-event.cjs');
const fakeCodex = join(repoRoot, 'tests', 'fixtures', 'fake-codex');

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
  process.stderr.write('codex-flow integration: SKIPPED (no `tmux` on PATH)\n');
}

let uniqueCounter = 0;
function uniqueName(): string {
  uniqueCounter += 1;
  return `csd-cx-${process.pid}-${uniqueCounter}-${Math.random().toString(36).slice(2, 8)}`;
}

describe.skipIf(!HAS_TMUX)('codex flow e2e (real tmux + bundled csd)', () => {
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
    workerDir = mkdtempSync(join(tmpdir(), 'csd-cx-wd-'));
    home = mkdtempSync(join(tmpdir(), 'csd-cx-home-'));
    cwd = mkdtempSync(join(tmpdir(), 'csd-cx-cwd-'));
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
   * Launch a codex worker via the bundled CLI; returns the printed shim path.
   * The bundled hook is pointed at by CSD_EMIT_EVENT_PATH so the codex driver
   * bakes the real `dist/emit-event.cjs` into the worker's config.toml.
   */
  async function launch(): Promise<{ stdout: string; stderr: string }> {
    const result = await runWithEnv(
      ['node', csdEntry, 'launch', tmuxName, cwd, '--harness', 'codex'],
      {
        CSD_CODEX_BIN: fakeCodex,
        CSD_EMIT_EVENT_PATH: emitEvent,
        CSD_WORKER_DIR: workerDir,
        HOME: home,
        CLAUDE_PLUGIN_ROOT: repoRoot,
      },
    );
    expect(result.code, `launch failed:\n${result.stderr}`).toBe(0);
    return { stdout: result.stdout.trim(), stderr: result.stderr };
  }

  /** Poll until the worker's meta self-registers (codex's boot turn), or fail. */
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

  it('launches a codex worker: derive panel + executable shim, NO meta at launch', async () => {
    const { stdout: shim, stderr: panel } = await launch();

    // stdout is the deterministic shim path, and the file is executable.
    expect(shim).toBe(join(workerDir, 'bin', tmuxName));
    expect(existsSync(shim)).toBe(true);
    expect(statSync(shim).mode & 0o100).toBeTruthy();

    // The derive panel doesn't claim a specific id-assignment timing.
    expect(panel).toContain(
      'session_id: (derive — minted by the harness on registration)',
    );
    expect(panel).toContain(
      'events:     (available after the worker registers)',
    );

    // The tmux session is live and the sidecar harness marker exists.
    expect(hasSession(tmuxName)).toBe(true);
    expect(readFileSync(join(workerDir, `${tmuxName}.harness`), 'utf8')).toBe(
      'codex',
    );

    await worker('stop');
  });

  it('the boot turn self-registers the meta; status + read-turn resolve via the codex driver', async () => {
    await launch();

    // The fake fires a boot turn (SessionStart -> ... -> Stop); the hook self-
    // registers <sid>.meta. Once that lands, the worker resolves by tmux name.
    const sid = await awaitRegistered();
    expect(sid.length).toBeGreaterThan(0);

    // A real <sid>.meta was self-registered (csd wrote none at launch).
    const metas = readdirSync(workerDir).filter((f) => f.endsWith('.meta'));
    expect(metas).toEqual([`${sid}.meta`]);

    // status resolves (codex driver, by tmux name -> sid). The boot turn ended
    // with Stop, so the worker is idle.
    const status = await worker('status');
    expect(status.code, status.stderr).toBe(0);
    expect(status.stdout.trim()).toBe('idle');

    // read-turn renders the codex rollout (driver resolved from meta.harness).
    const turn = await worker('read-turn');
    expect(turn.code, turn.stderr).toBe(0);
    expect(turn.stdout).toContain('FAKE_DONE');

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
