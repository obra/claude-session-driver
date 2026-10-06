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
import { getDriver } from '../src/harness/registry.js';

function tmpDir(): string {
  return mkdtempSync(join(tmpdir(), 'csd-await-'));
}

const SID = 'sid-await';
const TMUX_NAME = 'await-worker';

interface FakeTmuxCalls {
  capturePane: string[];
  sendEnter: string[];
  killSession: string[];
  sendKey?: string[];
}

function fakeTmux(
  calls: FakeTmuxCalls,
  paneText: () => string,
  onSendEnter?: () => void,
  onSendKey?: (key: string) => void,
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
    async sendKey(_name: string, key: string) {
      calls.sendKey?.push(key);
      onSendKey?.(key);
    },
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
    cwd: '/home/user/project',
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
    const result = await awaitSessionStart(ctx, TMUX_NAME, SID, {
      trustTimeoutMs: 100,
      startTimeoutMs: 2000,
      pollMs: 10,
    });
    expect(result.started).toBe(true);
    // The discriminated union guarantees no failureMessage on success.
    expect('failureMessage' in result).toBe(false);
    // No teardown on success.
    expect(calls.killSession).toHaveLength(0);
    expect(existsSync(metaPath(workerDir, SID))).toBe(true);
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
      () => 'Do you trust this folder?',
      () => {
        appendEvent(ef, { event: 'session_start', ts: '2025-01-01T00:00:00Z' });
      },
    );
    const ctx = makeCtx(workerDir, tmux);
    const result = await awaitSessionStart(ctx, TMUX_NAME, SID, {
      trustTimeoutMs: 1000,
      startTimeoutMs: 2000,
      pollMs: 10,
    });
    expect(result.started).toBe(true);
    expect(calls.sendEnter).toContain(TMUX_NAME);
  });

  it('moves the trust dialog selection to "Yes" when it defaults to "No, exit"', async () => {
    const ef = eventsPath(workerDir, SID);
    const calls: FakeTmuxCalls = {
      capturePane: [],
      sendEnter: [],
      killSession: [],
      sendKey: [],
    };
    // Current Claude Code highlights "No, exit"; Enter there quits the worker.
    let selected = 'no';
    const pane = () =>
      selected === 'no'
        ? ' Quick safety check: Is this a project you created or one you trust?\n ❯ No, exit\n   Yes, I trust this folder\n'
        : ' Quick safety check: Is this a project you created or one you trust?\n   No, exit\n ❯ Yes, I trust this folder\n';
    const tmux = fakeTmux(
      calls,
      pane,
      () => {
        if (selected !== 'yes') throw new Error('Enter pressed on "No, exit"');
        appendEvent(ef, { event: 'session_start', ts: '2025-01-01T00:00:00Z' });
      },
      (key) => {
        if (key === 'Down') selected = 'yes';
      },
    );
    const ctx = makeCtx(workerDir, tmux);
    const result = await awaitSessionStart(ctx, TMUX_NAME, SID, {
      trustTimeoutMs: 1000,
      startTimeoutMs: 2000,
      pollMs: 10,
    });
    expect(result.started).toBe(true);
    expect(calls.sendKey).toEqual(['Down']);
    expect(calls.sendEnter).toEqual([TMUX_NAME]);
  });

  it('waits long enough by default for a trust dialog that appears after a slow start', async () => {
    const ef = eventsPath(workerDir, SID);
    const calls: FakeTmuxCalls = {
      capturePane: [],
      sendEnter: [],
      killSession: [],
    };
    // Claude with plugins loaded can take several seconds to draw the dialog.
    const shownAt = Date.now() + 6_000;
    const tmux = fakeTmux(
      calls,
      () =>
        Date.now() >= shownAt
          ? ' ❯ Yes, I trust this folder\n   No, exit\n'
          : 'starting...',
      () => {
        appendEvent(ef, { event: 'session_start', ts: '2025-01-01T00:00:00Z' });
      },
    );
    const ctx = makeCtx(workerDir, tmux);
    const result = await awaitSessionStart(ctx, TMUX_NAME, SID, {
      startTimeoutMs: 2000,
      pollMs: 50,
    });
    expect(result.started).toBe(true);
    expect(calls.sendEnter).toEqual([TMUX_NAME]);
  }, 15_000);

  it('times out: kills the session, removes meta+events, returns a failure message', async () => {
    // No session_start event is ever written, so the wait must time out.
    const calls: FakeTmuxCalls = {
      capturePane: [],
      sendEnter: [],
      killSession: [],
    };
    const tmux = fakeTmux(calls, () => 'line one\n\nlast visible line\n');
    const ctx = makeCtx(workerDir, tmux);
    const result = await awaitSessionStart(ctx, TMUX_NAME, SID, {
      trustTimeoutMs: 30,
      startTimeoutMs: 60,
      pollMs: 10,
    });
    expect(result.started).toBe(false);
    if (result.started) throw new Error('expected timeout failure');
    expect(result.failureMessage).toContain(
      'Error: Worker session failed to start within 30 seconds',
    );
    // Pane tail included in the failure message.
    expect(result.failureMessage).toContain('last visible line');
    // Teardown happened.
    expect(calls.killSession).toEqual([TMUX_NAME]);
    expect(existsSync(metaPath(workerDir, SID))).toBe(false);
    expect(existsSync(eventsPath(workerDir, SID))).toBe(false);
    expect(existsSync(shimPath(workerDir, TMUX_NAME))).toBe(false);
  });
});
