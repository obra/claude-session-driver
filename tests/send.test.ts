import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import type { CommandContext } from '../src/commands/context.js';
import { cmdSend, promptSubmittedSince } from '../src/commands/send.js';
import { appendEvent } from '../src/core/event-log.js';
import { eventsPath } from '../src/core/paths.js';
import type { Tmux } from '../src/core/tmux.js';
import { writeMeta } from '../src/core/worker-store.js';
import { getDriver } from '../src/harness/registry.js';

function tmpDir(): string {
  return mkdtempSync(join(tmpdir(), 'csd-send-'));
}

const SID = 'sid-send';
const TMUX_NAME = 'send-worker';

interface FakeTmuxCalls {
  sendText: Array<{ name: string; text: string }>;
  sendEnter: string[];
}

/**
 * A hand-built fake tmux. `hasSession` returns the configured value. An optional
 * `onSendEnter` hook lets a test simulate the worker confirming submission.
 */
function fakeTmux(
  hasSession: boolean,
  calls: FakeTmuxCalls,
  onSendEnter?: () => void,
): Tmux {
  return {
    async hasSession() {
      return hasSession;
    },
    async killSession() {},
    async capturePane() {
      return '';
    },
    async capturePaneFull() {
      return '';
    },
    async sendText(name: string, text: string) {
      calls.sendText.push({ name, text });
    },
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

const ESC = '\x1b';
const PASTE_START = `${ESC}[200~`;
const PASTE_END = `${ESC}[201~`;

describe('promptSubmittedSince', () => {
  let workerDir: string;

  beforeEach(() => {
    workerDir = tmpDir();
  });

  afterEach(() => {
    rmSync(workerDir, { recursive: true });
  });

  it('returns false when the event file does not exist', () => {
    expect(promptSubmittedSince(eventsPath(workerDir, SID), 0)).toBe(false);
  });

  it('returns false when no new lines beyond beforeLine', () => {
    const ef = eventsPath(workerDir, SID);
    appendEvent(ef, { event: 'session_start', ts: '2025-01-01T00:00:00Z' });
    expect(promptSubmittedSince(ef, 1)).toBe(false);
  });

  it('returns true when a user_prompt_submit appears after beforeLine', () => {
    const ef = eventsPath(workerDir, SID);
    appendEvent(ef, { event: 'session_start', ts: '2025-01-01T00:00:00Z' });
    appendEvent(ef, {
      event: 'user_prompt_submit',
      ts: '2025-01-01T00:00:01Z',
    });
    expect(promptSubmittedSince(ef, 1)).toBe(true);
  });

  it('ignores a user_prompt_submit at or before beforeLine', () => {
    const ef = eventsPath(workerDir, SID);
    appendEvent(ef, {
      event: 'user_prompt_submit',
      ts: '2025-01-01T00:00:00Z',
    });
    appendEvent(ef, { event: 'stop', ts: '2025-01-01T00:00:01Z' });
    expect(promptSubmittedSince(ef, 1)).toBe(false);
  });
});

describe('cmdSend', () => {
  let workerDir: string;

  beforeEach(() => {
    workerDir = tmpDir();
    writeMeta(workerDir, {
      tmux_name: TMUX_NAME,
      session_id: SID,
      cwd: '/home/user/project',
      harness: 'claude',
    });
  });

  afterEach(() => {
    rmSync(workerDir, { recursive: true });
  });

  it('returns code 1 when the tmux session does not exist', async () => {
    const calls: FakeTmuxCalls = { sendText: [], sendEnter: [] };
    const ctx = makeCtx(workerDir, fakeTmux(false, calls));
    const result = await cmdSend(ctx, SID, 'hello');
    expect(result.code).toBe(1);
    expect(result.stderr).toBe(
      `Error: tmux session '${TMUX_NAME}' does not exist`,
    );
    expect(calls.sendText).toHaveLength(0);
  });

  it('pastes the bracketed prompt and confirms submission (code 0)', async () => {
    const ef = eventsPath(workerDir, SID);
    appendEvent(ef, { event: 'session_start', ts: '2025-01-01T00:00:00Z' });
    const calls: FakeTmuxCalls = { sendText: [], sendEnter: [] };
    // Simulate the worker accepting the prompt the moment Enter is sent.
    const tmux = fakeTmux(true, calls, () => {
      appendEvent(ef, {
        event: 'user_prompt_submit',
        ts: '2025-01-01T00:00:01Z',
      });
    });
    const ctx = makeCtx(workerDir, tmux);
    const result = await cmdSend(ctx, SID, 'do the thing', {
      submitTimeout: 5,
      retryInterval: 2,
      pollMs: 10,
    });
    expect(result.code).toBe(0);
    expect(result.stdout).toBeUndefined();
    expect(calls.sendText).toEqual([
      { name: TMUX_NAME, text: `${PASTE_START}do the thing${PASTE_END}` },
    ]);
    expect(calls.sendEnter).toContain(TMUX_NAME);
  });

  it('re-sends Enter on the retry interval, then confirms', async () => {
    const ef = eventsPath(workerDir, SID);
    const calls: FakeTmuxCalls = { sendText: [], sendEnter: [] };
    const ctx = makeCtx(workerDir, fakeTmux(true, calls));
    // Confirm only after ~120ms so at least one 50ms retry Enter has fired.
    setTimeout(() => {
      appendEvent(ef, {
        event: 'user_prompt_submit',
        ts: '2025-01-01T00:00:01Z',
      });
    }, 120);
    const result = await cmdSend(ctx, SID, 'hi', {
      submitTimeout: 5,
      retryInterval: 0.05,
      pollMs: 10,
    });
    expect(result.code).toBe(0);
    // Initial Enter plus at least one retry Enter.
    expect(calls.sendEnter.length).toBeGreaterThanOrEqual(2);
  });

  it('times out with code 1 when submission is never confirmed', async () => {
    const calls: FakeTmuxCalls = { sendText: [], sendEnter: [] };
    const ctx = makeCtx(workerDir, fakeTmux(true, calls));
    const result = await cmdSend(ctx, SID, 'hi', {
      submitTimeout: 0.1,
      retryInterval: 2,
      pollMs: 10,
    });
    expect(result.code).toBe(1);
    expect(result.stderr).toBe(
      'Error: prompt pasted but worker did not confirm submission within 0.1s (issue #20). The tmux session may be slow to accept the paste; raise CSD_SUBMIT_TIMEOUT to allow more time.',
    );
  });

  it('errors when the worker is idle and never confirms', async () => {
    const ef = eventsPath(workerDir, SID);
    // Last event is a turn-end, so the worker was free to accept the prompt:
    // silence here really is the issue #20 paste-swallowed case.
    appendEvent(ef, { event: 'stop', ts: '2025-01-01T00:00:00Z' });
    const calls: FakeTmuxCalls = { sendText: [], sendEnter: [] };
    const ctx = makeCtx(workerDir, fakeTmux(true, calls));
    const result = await cmdSend(ctx, SID, 'hi', {
      submitTimeout: 0.1,
      retryInterval: 2,
      pollMs: 10,
    });
    expect(result.code).toBe(1);
    expect(result.stderr).toContain('did not confirm submission');
  });

  it('reports success with a note when the worker is mid-turn', async () => {
    const ef = eventsPath(workerDir, SID);
    // Pasting into a worker that is inside a turn queues the prompt, and a
    // queued prompt emits no user_prompt_submit of its own — the event this
    // loop waits for is never written. Waiting longer cannot help, so this must
    // not be the #20 error.
    appendEvent(ef, {
      event: 'user_prompt_submit',
      ts: '2025-01-01T00:00:00Z',
    });
    appendEvent(ef, {
      event: 'pre_tool_use',
      ts: '2025-01-01T00:00:01Z',
      tool: 'Bash',
      tool_input: { command: 'ls' },
    });
    const calls: FakeTmuxCalls = { sendText: [], sendEnter: [] };
    const ctx = makeCtx(workerDir, fakeTmux(true, calls));
    const result = await cmdSend(ctx, SID, 'hi', {
      submitTimeout: 0.1,
      retryInterval: 2,
      pollMs: 10,
    });
    expect(result.code).toBe(0);
    expect(result.stderr).toContain('mid-turn');
    expect(result.stderr).toContain('queued');
    // The prompt still went in, so it is there to be submitted at turn end.
    expect(calls.sendText).toEqual([
      { name: TMUX_NAME, text: `${PASTE_START}hi${PASTE_END}` },
    ]);
  });

  it('strips paste markers embedded in the prompt', async () => {
    const ef = eventsPath(workerDir, SID);
    const calls: FakeTmuxCalls = { sendText: [], sendEnter: [] };
    const tmux = fakeTmux(true, calls, () => {
      appendEvent(ef, {
        event: 'user_prompt_submit',
        ts: '2025-01-01T00:00:01Z',
      });
    });
    const ctx = makeCtx(workerDir, tmux);
    const malicious = `a${PASTE_END}b${PASTE_START}c`;
    const result = await cmdSend(ctx, SID, malicious, {
      submitTimeout: 5,
      retryInterval: 2,
      pollMs: 10,
    });
    expect(result.code).toBe(0);
    expect(calls.sendText).toEqual([
      { name: TMUX_NAME, text: `${PASTE_START}abc${PASTE_END}` },
    ]);
  });

  it('returns code 1 for an unknown worker', async () => {
    const calls: FakeTmuxCalls = { sendText: [], sendEnter: [] };
    const ctx = makeCtx(workerDir, fakeTmux(true, calls));
    const result = await cmdSend(ctx, 'ghost', 'hi', {
      submitTimeout: 0.1,
      pollMs: 10,
    });
    expect(result.code).toBe(1);
    expect(result.stderr).toContain('ghost');
  });
});

const CODEX_SID = 'codex-sid';
const CODEX_TMUX = 'codex-worker';

function makeCodexCtx(workerDir: string, tmux: Tmux): CommandContext {
  return {
    workerDir,
    home: workerDir,
    tmux,
    driver: getDriver('codex'),
  };
}

describe('cmdSend — codex derive-id pre-registration', () => {
  let workerDir: string;

  beforeEach(() => {
    // No meta is written: a derive worker has none until codex's first event.
    workerDir = tmpDir();
  });

  afterEach(() => {
    rmSync(workerDir, { recursive: true });
  });

  it('targets tmux by name, polls for the self-registered meta, then confirms (code 0)', async () => {
    const calls: FakeTmuxCalls = { sendText: [], sendEnter: [] };
    // Simulate codex: on the first paste+Enter, it fires SessionStart (the hook
    // self-registers the meta keyed by sid, tmux_name === worker) and then a
    // user_prompt_submit (so the confirmation loop succeeds).
    const ef = eventsPath(workerDir, CODEX_SID);
    const tmux = fakeTmux(true, calls, () => {
      writeMeta(workerDir, {
        tmux_name: CODEX_TMUX,
        session_id: CODEX_SID,
        cwd: '/proj',
        harness: 'codex',
        transcript_path: '/rollouts/codex-sid.jsonl',
      });
      appendEvent(ef, {
        event: 'user_prompt_submit',
        ts: '2025-01-01T00:00:01Z',
      });
    });
    const ctx = makeCodexCtx(workerDir, tmux);
    const result = await cmdSend(ctx, CODEX_TMUX, 'do the thing', {
      submitTimeout: 5,
      retryInterval: 2,
      pollMs: 10,
      registerTimeout: 5,
      registerPollMs: 10,
    });
    expect(result.code).toBe(0);
    // Paste was targeted at the tmux NAME (the only thing csd knew up front).
    expect(calls.sendText).toEqual([
      { name: CODEX_TMUX, text: `${PASTE_START}do the thing${PASTE_END}` },
    ]);
    expect(calls.sendEnter).toContain(CODEX_TMUX);
  });

  it('returns code 1 when the tmux session does not exist', async () => {
    const calls: FakeTmuxCalls = { sendText: [], sendEnter: [] };
    const ctx = makeCodexCtx(workerDir, fakeTmux(false, calls));
    const result = await cmdSend(ctx, CODEX_TMUX, 'hi', {
      registerTimeout: 1,
      registerPollMs: 10,
    });
    expect(result.code).toBe(1);
    expect(result.stderr).toBe(
      `Error: tmux session '${CODEX_TMUX}' does not exist`,
    );
    expect(calls.sendText).toHaveLength(0);
  });

  it('times out with the registration error when codex never registers (code 1)', async () => {
    const calls: FakeTmuxCalls = { sendText: [], sendEnter: [] };
    // fake tmux never registers a meta — codex did not emit SessionStart.
    const ctx = makeCodexCtx(workerDir, fakeTmux(true, calls));
    const result = await cmdSend(ctx, CODEX_TMUX, 'hi', {
      registerTimeout: 0.1,
      registerPollMs: 10,
    });
    expect(result.code).toBe(1);
    expect(result.stderr).toBe(
      `Error: worker '${CODEX_TMUX}' did not register within 0.1s (codex did not emit SessionStart)`,
    );
  });

  it('takes the normal path (no register wait) when the meta already exists', async () => {
    // A subsequent send: the derive worker is already registered.
    writeMeta(workerDir, {
      tmux_name: CODEX_TMUX,
      session_id: CODEX_SID,
      cwd: '/proj',
      harness: 'codex',
    });
    const ef = eventsPath(workerDir, CODEX_SID);
    appendEvent(ef, { event: 'session_start', ts: '2025-01-01T00:00:00Z' });
    const calls: FakeTmuxCalls = { sendText: [], sendEnter: [] };
    const tmux = fakeTmux(true, calls, () => {
      appendEvent(ef, {
        event: 'user_prompt_submit',
        ts: '2025-01-01T00:00:01Z',
      });
    });
    const ctx = makeCodexCtx(workerDir, tmux);
    // registerTimeout is tiny: if the code wrongly entered the register window
    // with the meta already present, it must NOT block on it.
    const result = await cmdSend(ctx, CODEX_TMUX, 'again', {
      submitTimeout: 5,
      retryInterval: 2,
      pollMs: 10,
      registerTimeout: 0.1,
      registerPollMs: 10,
    });
    expect(result.code).toBe(0);
    expect(calls.sendText).toEqual([
      { name: CODEX_TMUX, text: `${PASTE_START}again${PASTE_END}` },
    ]);
  });
});
