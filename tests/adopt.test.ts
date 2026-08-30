import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  realpathSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { cmdAdopt } from '../src/commands/adopt.js';
import type { CommandContext } from '../src/commands/context.js';
import { grantConsent } from '../src/core/consent.js';
import { appendEvent } from '../src/core/event-log.js';
import { eventsPath, shimPath } from '../src/core/paths.js';
import type { Tmux } from '../src/core/tmux.js';
import {
  readHarnessMarker,
  readMeta,
  writeHarnessMarker,
} from '../src/core/worker-store.js';
import { grantWorkspaceTrust } from '../src/core/workspace-trust.js';
import { getDriver } from '../src/harness/registry.js';

function tmpDir(prefix: string): string {
  return mkdtempSync(join(tmpdir(), prefix));
}

interface SessionCall {
  name: string;
  cwd: string;
  env: Record<string, string>;
  argv: string[];
}

interface FakeTmuxState {
  hasSession: boolean;
  newSession: SessionCall[];
  respawnPane: SessionCall[];
}

function fakeTmux(state: FakeTmuxState, onStart?: () => void): Tmux {
  return {
    async hasSession() {
      return state.hasSession;
    },
    async killSession() {},
    async capturePane() {
      return '';
    },
    async capturePaneFull() {
      return '';
    },
    async sendText() {},
    async sendEnter() {},
    async sendKey() {},
    async newSession(name, cwd, env, argv) {
      state.newSession.push({ name, cwd, env, argv });
      onStart?.();
    },
    async respawnPane(name, cwd, env, argv) {
      state.respawnPane.push({ name, cwd, env, argv });
      onStart?.();
    },
  };
}

function makeCtx(workerDir: string, home: string, tmux: Tmux): CommandContext {
  return { workerDir, home, tmux, driver: getDriver('claude') };
}

function freshState(): FakeTmuxState {
  return { hasSession: false, newSession: [], respawnPane: [] };
}

const FAST = { startTimeoutMs: 2000, pollMs: 10 };
const SID = 'abcd1234-5678-90ab-cdef-1234567890ab';

describe('cmdAdopt', () => {
  let workerDir: string;
  let home: string;
  let cwd: string;
  let rawCwd: string;

  beforeEach(() => {
    workerDir = tmpDir('csd-adopt-wd-');
    home = tmpDir('csd-adopt-home-');
    rawCwd = tmpDir('csd-adopt-cwd-');
    cwd = realpathSync(rawCwd);
  });

  afterEach(() => {
    rmSync(workerDir, { recursive: true });
    rmSync(home, { recursive: true });
    rmSync(rawCwd, { recursive: true });
  });

  const baseOpts = () => ({
    pluginDir: '/plugins/superpowers',
    csdEntry: '/dist/csd.cjs',
    csdPath: '/usr/local/bin/csd',
  });

  /** Create the Claude transcript adopt's pre-flight requires (N-1). */
  function seedTranscript(sid = SID): void {
    const t = getDriver('claude').transcriptPath(sid, cwd, home);
    mkdirSync(dirname(t), { recursive: true });
    writeFileSync(t, '{"type":"user","message":{"content":"hi"}}\n');
  }

  it('fails fast with a clear error when the session transcript does not exist (N-1)', async () => {
    grantConsent(home);
    const ctx = makeCtx(workerDir, home, fakeTmux(freshState()));
    const result = await cmdAdopt(
      ctx,
      { tmuxName: 'w1', cwd, sessionId: SID, extraArgs: [] },
      { ...baseOpts(), ...FAST },
    );
    expect(result.code).toBe(1);
    expect(result.stderr).toContain(`no transcript found for session '${SID}'`);
    // Failed before touching tmux or writing any worker state.
    expect(readMeta(workerDir, SID)).toBeNull();
  });

  it('errors when cwd does not exist', async () => {
    grantConsent(home);
    const ctx = makeCtx(workerDir, home, fakeTmux(freshState()));
    const result = await cmdAdopt(
      ctx,
      { tmuxName: 'w1', cwd: '/no/such/dir', sessionId: SID, extraArgs: [] },
      { ...baseOpts(), ...FAST },
    );
    expect(result.code).toBe(1);
    expect(result.stderr).toContain("cwd '/no/such/dir' does not exist");
  });

  it('errors when the session id does not look like a Claude session id', async () => {
    grantConsent(home);
    const ctx = makeCtx(workerDir, home, fakeTmux(freshState()));
    const result = await cmdAdopt(
      ctx,
      { tmuxName: 'w1', cwd, sessionId: 'nope', extraArgs: [] },
      { ...baseOpts(), ...FAST },
    );
    expect(result.code).toBe(1);
    expect(result.stderr).toContain(
      "'nope' does not look like a Claude session id",
    );
  });

  it('errors when consent has not been granted', async () => {
    const ctx = makeCtx(workerDir, home, fakeTmux(freshState()));
    const result = await cmdAdopt(
      ctx,
      { tmuxName: 'w1', cwd, sessionId: SID, extraArgs: [] },
      { ...baseOpts(), ...FAST },
    );
    expect(result.code).toBe(1);
    expect(result.stderr).toContain('requires one-time consent');
  });

  it('refuses to adopt over a non-claude worker, leaving it intact (BUG-2)', async () => {
    grantConsent(home);
    // A codex worker owns this tmux name (its .harness sidecar records the
    // harness) and its pane is live.
    writeHarnessMarker(workerDir, 'codex-worker', 'codex');
    const state: FakeTmuxState = {
      hasSession: true,
      newSession: [],
      respawnPane: [],
    };
    const ctx = makeCtx(workerDir, home, fakeTmux(state));
    const result = await cmdAdopt(
      ctx,
      { tmuxName: 'codex-worker', cwd, sessionId: SID, extraArgs: [] },
      { ...baseOpts(), ...FAST },
    );
    expect(result.code).toBe(1);
    expect(result.stderr).toContain('codex');
    // The worker is NOT clobbered: no pane respawn/new-session, sidecar intact,
    // and adopt did not overwrite its identity with a claude meta.
    expect(state.respawnPane).toHaveLength(0);
    expect(state.newSession).toHaveLength(0);
    expect(readHarnessMarker(workerDir, 'codex-worker')).toBe('codex');
    expect(readMeta(workerDir, SID)).toBeNull();
  });

  it('adopts with NO existing session: opens a new pane with --resume', async () => {
    grantConsent(home);
    seedTranscript();
    const state = freshState();
    // The meta must already exist when the pane is created (the SessionStart
    // hook needs it to record events), so assert it from the launch callback.
    let metaExistedAtLaunch = false;
    const ctx = makeCtx(
      workerDir,
      home,
      fakeTmux(state, () => {
        metaExistedAtLaunch = readMeta(workerDir, SID) !== null;
        appendEvent(eventsPath(workerDir, SID), {
          event: 'session_start',
          ts: '2025-01-01T00:00:00Z',
        });
      }),
    );
    const result = await cmdAdopt(
      ctx,
      { tmuxName: 'w1', cwd, sessionId: SID, extraArgs: ['--verbose'] },
      { ...baseOpts(), ...FAST },
    );

    expect(result.code).toBe(0);
    expect(metaExistedAtLaunch).toBe(true);
    // New pane path.
    expect(state.newSession).toHaveLength(1);
    expect(state.respawnPane).toHaveLength(0);
    const call = state.newSession[0]!;
    expect(call.argv).toContain('--resume');
    expect(call.argv).toContain(SID);
    expect(call.argv).not.toContain('--session-id');
    expect(call.argv.slice(-1)).toEqual(['--verbose']);
    expect(call.env.CLAUDE_CODE_SSE_PORT).toBe('');

    // stdout = shim path; panel says "opened new pane".
    expect(result.stdout).toBe(shimPath(workerDir, 'w1'));
    expect(result.stderr).toContain('Worker adopted (opened new pane).');
    expect(result.stderr).toContain(`session_id: ${SID}`);
    expect(result.stderr).toContain('reproduce: /usr/local/bin/csd adopt');

    // Meta is keyed by the supplied sessionId, with the adopt invocation.
    const meta = readMeta(workerDir, SID);
    expect(meta).toMatchObject({
      tmux_name: 'w1',
      session_id: SID,
      cwd,
      harness: 'claude',
    });
    expect(meta?.invocation).toEqual(['w1', cwd, SID, '--', '--verbose']);

    // Shim is executable.
    expect(statSync(shimPath(workerDir, 'w1')).mode & 0o100).toBeTruthy();
  });

  it('adopts WITH an existing session: respawns the pane in place', async () => {
    grantConsent(home);
    seedTranscript();
    const state = freshState();
    state.hasSession = true;
    const ctx = makeCtx(
      workerDir,
      home,
      fakeTmux(state, () => {
        appendEvent(eventsPath(workerDir, SID), {
          event: 'session_start',
          ts: '2025-01-01T00:00:00Z',
        });
      }),
    );
    const result = await cmdAdopt(
      ctx,
      { tmuxName: 'w1', cwd, sessionId: SID, extraArgs: [] },
      { ...baseOpts(), ...FAST },
    );

    expect(result.code).toBe(0);
    expect(state.respawnPane).toHaveLength(1);
    expect(state.newSession).toHaveLength(0);
    const call = state.respawnPane[0]!;
    expect(call.argv).toContain('--resume');
    expect(call.argv).toContain(SID);
    expect(result.stderr).toContain(
      'Worker adopted (respawned existing pane).',
    );

    const meta = readMeta(workerDir, SID);
    // No extra args: invocation omits the -- separator.
    expect(meta?.invocation).toEqual(['w1', cwd, SID]);
  });

  it('uses the same workspace grant when adopt encounters the trust prompt', async () => {
    grantConsent(home);
    grantWorkspaceTrust(home, cwd);
    seedTranscript();
    const state = freshState();
    const enter: string[] = [];
    const base = fakeTmux(state);
    const tmux: Tmux = {
      ...base,
      async capturePane() {
        return 'Do you trust this folder?';
      },
      async sendEnter(name) {
        enter.push(name);
        appendEvent(eventsPath(workerDir, SID), {
          event: 'session_start',
          ts: 'T',
        });
      },
    };
    const result = await cmdAdopt(
      makeCtx(workerDir, home, tmux),
      { tmuxName: 'w1', cwd, sessionId: SID, extraArgs: [] },
      { ...baseOpts(), ...FAST },
    );
    expect(result.code).toBe(0);
    expect(enter).toEqual(['w1']);
  });

  it('ignores a stale session_start and rejects an ungranted trust prompt', async () => {
    grantConsent(home);
    seedTranscript();
    appendEvent(eventsPath(workerDir, SID), {
      event: 'session_start',
      ts: 'old',
    });
    const state = freshState();
    state.hasSession = true;
    const enter: string[] = [];
    const killed: string[] = [];
    const base = fakeTmux(state);
    const tmux: Tmux = {
      ...base,
      async capturePane() {
        return 'Do you trust this folder?';
      },
      async sendEnter(name) {
        enter.push(name);
      },
      async killSession(name) {
        killed.push(name);
      },
    };

    const result = await cmdAdopt(
      makeCtx(workerDir, home, tmux),
      { tmuxName: 'w1', cwd, sessionId: SID, extraArgs: [] },
      { ...baseOpts(), ...FAST },
    );

    expect(result.code).toBe(1);
    expect(result.stderr).toContain('requires workspace trust');
    expect(state.respawnPane).toHaveLength(1);
    expect(enter).toEqual([]);
    expect(killed).toEqual(['w1']);
    expect(readMeta(workerDir, SID)).toBeNull();
    expect(existsSync(eventsPath(workerDir, SID))).toBe(false);
  });

  it('ignores a stale session_start and succeeds on the new attempt event', async () => {
    grantConsent(home);
    seedTranscript();
    appendEvent(eventsPath(workerDir, SID), {
      event: 'session_start',
      ts: 'old',
    });
    const state = freshState();
    state.hasSession = true;
    let sawStaleLogBeforeRespawn = false;
    const ctx = makeCtx(
      workerDir,
      home,
      fakeTmux(state, () => {
        sawStaleLogBeforeRespawn = true;
        appendEvent(eventsPath(workerDir, SID), {
          event: 'session_start',
          ts: 'new',
        });
      }),
    );

    const result = await cmdAdopt(
      ctx,
      { tmuxName: 'w1', cwd, sessionId: SID, extraArgs: [] },
      { ...baseOpts(), ...FAST },
    );

    expect(result.code).toBe(0);
    expect(sawStaleLogBeforeRespawn).toBe(true);
    expect(state.respawnPane).toHaveLength(1);
  });

  it('pre-writes the meta before launch and tears it down on proof-of-life failure', async () => {
    grantConsent(home);
    seedTranscript();
    const state = freshState();
    // The worker never emits session_start, so the wait times out.
    const ctx = makeCtx(workerDir, home, fakeTmux(state));
    const result = await cmdAdopt(
      ctx,
      { tmuxName: 'w1', cwd, sessionId: SID, extraArgs: [] },
      { ...baseOpts(), startTimeoutMs: 40, pollMs: 10 },
    );
    expect(result.code).toBe(1);
    expect(result.stderr).toContain(
      'Error: Worker session failed to start within 30 seconds',
    );
    // Teardown removed the pre-written meta.
    expect(readMeta(workerDir, SID)).toBeNull();
  });
});
