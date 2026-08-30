import { existsSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { awaitSessionStart } from '../src/commands/await-start.js';
import type { CommandContext } from '../src/commands/context.js';
import { appendEvent } from '../src/core/event-log.js';
import { eventsPath, metaPath, shimPath } from '../src/core/paths.js';
import type { Tmux } from '../src/core/tmux.js';
import { writeMeta, writeShim } from '../src/core/worker-store.js';
import { grantWorkspaceTrust } from '../src/core/workspace-trust.js';
import { getDriver } from '../src/harness/registry.js';

function tmpDir(): string {
  return mkdtempSync(join(tmpdir(), 'csd-await-'));
}

const SID = 'sid-await';
const TMUX_NAME = 'await-worker';
const CWD = '/home/user/project';
const EXIT_TRUST_PROMPT = 'Yes, I trust this folder\nNo, exit';
const CONTINUE_TRUST_PROMPT =
  'Yes,\n  I trust this folder\nNo, continue\n  without these permissions';
const FAST = {
  cwd: CWD,
  csdPath: '/usr/local/bin/csd',
  afterLine: 0,
  startTimeoutMs: 2000,
  pollMs: 10,
};

interface FakeTmuxCalls {
  capturePane: string[];
  sendEnter: string[];
  killSession: string[];
}

function fakeTmux(
  calls: FakeTmuxCalls,
  paneText: () => string,
  onSendEnter?: () => void,
): Tmux {
  return {
    async hasSession() {
      return true;
    },
    async killSession(name: string) {
      calls.killSession.push(name);
    },
    async capturePane(name: string) {
      calls.capturePane.push(name);
      return paneText();
    },
    async capturePaneFull() {
      return paneText();
    },
    async sendText() {},
    async sendEnter(name: string) {
      calls.sendEnter.push(name);
      onSendEnter?.();
    },
    async sendKey() {},
    async newSession() {},
    async respawnPane() {},
  };
}

function makeCtx(workerDir: string, tmux: Tmux): CommandContext {
  return {
    workerDir,
    home: workerDir,
    tmux,
    driver: getDriver('claude'),
  };
}

function seedWorker(workerDir: string): void {
  writeMeta(workerDir, {
    tmux_name: TMUX_NAME,
    session_id: SID,
    cwd: CWD,
    harness: 'claude',
  });
  writeShim(workerDir, TMUX_NAME, '/path/to/csd.js');
}

describe('awaitSessionStart', () => {
  let workerDir: string;

  beforeEach(() => {
    workerDir = tmpDir();
    seedWorker(workerDir);
  });

  afterEach(() => {
    rmSync(workerDir, { recursive: true });
  });

  it('returns started when a session_start event appears', async () => {
    const ef = eventsPath(workerDir, SID);
    const calls: FakeTmuxCalls = {
      capturePane: [],
      sendEnter: [],
      killSession: [],
    };
    const tmux = fakeTmux(calls, () => '');
    const ctx = makeCtx(workerDir, tmux);
    // Worker emits session_start shortly after launch.
    setTimeout(() => {
      appendEvent(ef, { event: 'session_start', ts: '2025-01-01T00:00:00Z' });
    }, 30);
    const result = await awaitSessionStart(ctx, TMUX_NAME, SID, FAST);
    expect(result.started).toBe(true);
    // The discriminated union guarantees no failureMessage on success.
    expect('failureMessage' in result).toBe(false);
    // No teardown on success.
    expect(calls.killSession).toHaveLength(0);
    expect(calls.sendEnter).toEqual([]);
    expect(existsSync(metaPath(workerDir, SID))).toBe(true);
  });

  it('ignores an old session_start and accepts a new one after the attempt baseline', async () => {
    const ef = eventsPath(workerDir, SID);
    appendEvent(ef, { event: 'session_start', ts: 'old' });
    const afterLine = 1;
    const calls: FakeTmuxCalls = {
      capturePane: [],
      sendEnter: [],
      killSession: [],
    };
    const ctx = makeCtx(
      workerDir,
      fakeTmux(calls, () => ''),
    );
    setTimeout(() => {
      appendEvent(ef, { event: 'session_start', ts: 'new' });
    }, 30);

    const result = await awaitSessionStart(ctx, TMUX_NAME, SID, {
      ...FAST,
      afterLine,
    });

    expect(result.started).toBe(true);
    expect(calls.capturePane.length).toBeGreaterThan(0);
    expect(calls.killSession).toEqual([]);
  });

  it('accepts the trust dialog by sending Enter when the pane prompts', async () => {
    const ef = eventsPath(workerDir, SID);
    const calls: FakeTmuxCalls = {
      capturePane: [],
      sendEnter: [],
      killSession: [],
    };
    // Pane shows the trust prompt; once Enter is sent, the worker starts.
    const tmux = fakeTmux(
      calls,
      () => EXIT_TRUST_PROMPT,
      () => {
        appendEvent(ef, { event: 'session_start', ts: '2025-01-01T00:00:00Z' });
      },
    );
    const ctx = makeCtx(workerDir, tmux);
    grantWorkspaceTrust(ctx.home, CWD);
    const result = await awaitSessionStart(ctx, TMUX_NAME, SID, FAST);
    expect(result.started).toBe(true);
    expect(calls.sendEnter).toContain(TMUX_NAME);
  });

  it('detects a workspace trust prompt late in the full start window', async () => {
    const ef = eventsPath(workerDir, SID);
    const calls: FakeTmuxCalls = {
      capturePane: [],
      sendEnter: [],
      killSession: [],
    };
    let captures = 0;
    const tmux = fakeTmux(
      calls,
      () => {
        captures += 1;
        return captures >= 4 ? CONTINUE_TRUST_PROMPT : '';
      },
      () => {
        appendEvent(ef, { event: 'session_start', ts: 'T' });
      },
    );
    const ctx = makeCtx(workerDir, tmux);
    grantWorkspaceTrust(ctx.home, CWD);

    const result = await awaitSessionStart(ctx, TMUX_NAME, SID, {
      ...FAST,
      startTimeoutMs: 500,
    });
    expect(result.started).toBe(true);
    expect(captures).toBeGreaterThanOrEqual(4);
    expect(calls.sendEnter).toEqual([TMUX_NAME]);
  });

  it('fails fast without mutating worker state when a recognized trust prompt has no grant', async () => {
    const calls: FakeTmuxCalls = {
      capturePane: [],
      sendEnter: [],
      killSession: [],
    };
    const tmux = fakeTmux(calls, () => EXIT_TRUST_PROMPT);
    const ctx = makeCtx(workerDir, tmux);
    const startedAt = Date.now();
    const result = await awaitSessionStart(ctx, TMUX_NAME, SID, {
      ...FAST,
      startTimeoutMs: 10_000,
    });

    expect(result.started).toBe(false);
    if (result.started) throw new Error('expected workspace trust failure');
    expect(Date.now() - startedAt).toBeLessThan(1000);
    expect(calls.sendEnter).toEqual([]);
    expect(calls.killSession).toEqual([]);
    expect(result.failureMessage).toContain(CWD);
    expect(result.failureMessage).toContain(
      `/usr/local/bin/csd grant-workspace-trust ${CWD}`,
    );
    expect(existsSync(metaPath(workerDir, SID))).toBe(true);
    expect(existsSync(shimPath(workerDir, TMUX_NAME))).toBe(true);
  });

  it('shell-quotes the exact grant command for paths with spaces', async () => {
    const calls: FakeTmuxCalls = {
      capturePane: [],
      sendEnter: [],
      killSession: [],
    };
    const ctx = makeCtx(
      workerDir,
      fakeTmux(calls, () => EXIT_TRUST_PROMPT),
    );
    const result = await awaitSessionStart(ctx, TMUX_NAME, SID, {
      cwd: '/workspace with spaces',
      csdPath: '/plugin path/dist/csd.cjs',
      afterLine: 0,
      startTimeoutMs: 10_000,
      pollMs: 10,
    });
    expect(result.started).toBe(false);
    if (result.started) throw new Error('expected workspace trust failure');
    expect(result.failureMessage).toContain(
      "node '/plugin path/dist/csd.cjs' grant-workspace-trust '/workspace with spaces'",
    );
  });

  it('does not treat a historical trust phrase without a cancel label as the prompt', async () => {
    const calls: FakeTmuxCalls = {
      capturePane: [],
      sendEnter: [],
      killSession: [],
    };
    const ctx = makeCtx(
      workerDir,
      fakeTmux(
        calls,
        () => 'Earlier output mentioned: "Yes, I trust this folder".',
      ),
    );
    grantWorkspaceTrust(ctx.home, CWD);

    const result = await awaitSessionStart(ctx, TMUX_NAME, SID, {
      ...FAST,
      startTimeoutMs: 40,
    });

    expect(result.started).toBe(false);
    expect(calls.sendEnter).toEqual([]);
    expect(calls.killSession).toEqual([]);
  });

  it('does not auto-accept a different external-import prompt', async () => {
    const calls: FakeTmuxCalls = {
      capturePane: [],
      sendEnter: [],
      killSession: [],
    };
    const ctx = makeCtx(
      workerDir,
      fakeTmux(calls, () => 'Allow external CLAUDE.md file imports?'),
    );
    grantWorkspaceTrust(ctx.home, CWD);
    const result = await awaitSessionStart(ctx, TMUX_NAME, SID, {
      ...FAST,
      startTimeoutMs: 40,
    });
    expect(result.started).toBe(false);
    expect(calls.sendEnter).toEqual([]);
    expect(calls.killSession).toEqual([]);
  });

  it('times out without cleanup and returns a failure message to the owner', async () => {
    // No session_start event is ever written, so the wait must time out.
    const calls: FakeTmuxCalls = {
      capturePane: [],
      sendEnter: [],
      killSession: [],
    };
    const tmux = fakeTmux(calls, () => 'line one\n\nlast visible line\n');
    const ctx = makeCtx(workerDir, tmux);
    const result = await awaitSessionStart(ctx, TMUX_NAME, SID, {
      ...FAST,
      startTimeoutMs: 60,
    });
    expect(result.started).toBe(false);
    if (result.started) throw new Error('expected timeout failure');
    expect(result.failureMessage).toContain(
      'Error: Worker session failed to start within 30 seconds',
    );
    // Pane tail included in the failure message.
    expect(result.failureMessage).toContain('last visible line');
    // Resource owners, not the observer, decide how to roll back.
    expect(calls.killSession).toEqual([]);
    expect(existsSync(metaPath(workerDir, SID))).toBe(true);
    expect(existsSync(eventsPath(workerDir, SID))).toBe(false);
    expect(existsSync(shimPath(workerDir, TMUX_NAME))).toBe(true);
  });
});
