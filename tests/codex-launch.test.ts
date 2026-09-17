import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import {
  awaitComposerReady,
  dismissCodexTrustGate,
} from '../src/commands/codex-launch.js';
import type { CommandContext } from '../src/commands/context.js';
import type { Tmux } from '../src/core/tmux.js';
import { getDriver } from '../src/harness/registry.js';

function tmpDir(): string {
  return mkdtempSync(join(tmpdir(), 'csd-codex-launch-'));
}

interface FakeTmuxCalls {
  capturePane: string[];
  sendText: { name: string; text: string }[];
  sendEnter: string[];
}

/**
 * A fake tmux whose pane text is computed per-capture by `paneText` (so a test
 * can return the trust gate or the composer glyph on demand, or never match).
 */
function fakeTmux(calls: FakeTmuxCalls, paneText: () => string): Tmux {
  return {
    async hasSession() {
      return true;
    },
    async killSession() {},
    async capturePane(name: string) {
      calls.capturePane.push(name);
      return paneText();
    },
    async capturePaneFull() {
      return paneText();
    },
    async sendText(name: string, text: string) {
      calls.sendText.push({ name, text });
    },
    async sendEnter(name: string) {
      calls.sendEnter.push(name);
    },
    async sendKey() {},
    async newSession() {},
    async respawnPane() {},
  };
}

function freshCalls(): FakeTmuxCalls {
  return { capturePane: [], sendText: [], sendEnter: [] };
}

function makeCtx(workerDir: string, tmux: Tmux): CommandContext {
  return { workerDir, home: workerDir, tmux, driver: getDriver('codex') };
}

const TMUX_NAME = 'codex-worker';
// Tiny windows so the never-match cases settle fast.
const FAST = { timeoutMs: 60, pollMs: 10, settleMs: 0 };

describe('dismissCodexTrustGate', () => {
  let workerDir: string;

  beforeEach(() => {
    workerDir = tmpDir();
  });

  afterEach(() => {
    rmSync(workerDir, { recursive: true });
  });

  it('sends "2" then Enter when the trust gate text appears', async () => {
    const calls = freshCalls();
    const ctx = makeCtx(
      workerDir,
      fakeTmux(calls, () => 'Hooks need review'),
    );
    await dismissCodexTrustGate(ctx, TMUX_NAME, FAST);
    expect(calls.sendText).toEqual([{ name: TMUX_NAME, text: '2' }]);
    expect(calls.sendEnter).toEqual([TMUX_NAME]);
  });

  it('matches the alternate "Trust all and continue" phrasing (case-insensitive)', async () => {
    const calls = freshCalls();
    const ctx = makeCtx(
      workerDir,
      fakeTmux(calls, () => 'Press 2 to Trust all and continue'),
    );
    await dismissCodexTrustGate(ctx, TMUX_NAME, FAST);
    expect(calls.sendText).toEqual([{ name: TMUX_NAME, text: '2' }]);
    expect(calls.sendEnter).toEqual([TMUX_NAME]);
  });

  it('returns without sending anything when the gate never appears (best-effort)', async () => {
    const calls = freshCalls();
    const ctx = makeCtx(
      workerDir,
      fakeTmux(calls, () => 'just a normal pane'),
    );
    await dismissCodexTrustGate(ctx, TMUX_NAME, FAST);
    expect(calls.sendText).toEqual([]);
    expect(calls.sendEnter).toEqual([]);
    // It polled at least once before giving up.
    expect(calls.capturePane.length).toBeGreaterThan(0);
  });
});

describe('awaitComposerReady', () => {
  let workerDir: string;

  beforeEach(() => {
    workerDir = tmpDir();
  });

  afterEach(() => {
    rmSync(workerDir, { recursive: true });
  });

  it('returns once the idle composer (glyph + placeholder) appears', async () => {
    const calls = freshCalls();
    // Big timeout so the test only finishes fast if the glyph is seen.
    const ctx = makeCtx(
      workerDir,
      fakeTmux(calls, () => '› Ask Codex to do anything'),
    );
    await awaitComposerReady(ctx, TMUX_NAME, {
      timeoutMs: 5000,
      pollMs: 10,
    });
    expect(calls.capturePane.length).toBeGreaterThan(0);
  });

  it('returns after the timeout when the glyph never appears (best-effort)', async () => {
    const calls = freshCalls();
    const ctx = makeCtx(
      workerDir,
      fakeTmux(calls, () => 'no glyph here'),
    );
    // Must resolve (not throw, not hang) even though the glyph never shows.
    await awaitComposerReady(ctx, TMUX_NAME, { timeoutMs: 50, pollMs: 10 });
    expect(calls.capturePane.length).toBeGreaterThan(0);
  });
});
