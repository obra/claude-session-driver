import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import type { CommandContext } from '../src/commands/context.js';
import { cmdConverse } from '../src/commands/converse.js';
import { appendEvent } from '../src/core/event-log.js';
import { claudeTranscriptPath, eventsPath } from '../src/core/paths.js';
import type { Tmux } from '../src/core/tmux.js';
import { writeMeta } from '../src/core/worker-store.js';
import { getDriver } from '../src/harness/registry.js';

function tmpDir(prefix: string): string {
  return mkdtempSync(join(tmpdir(), prefix));
}

const SID = 'sid-converse';
const TMUX_NAME = 'converse-worker';
const CWD = '/home/user/project';

const EARLIER_PROMPT = '{"type":"user","message":{"content":"earlier prompt"}}';
const ASSISTANT_BEFORE =
  '{"type":"assistant","message":{"content":[{"type":"text","text":"earlier reply"}]}}';
const USER_PROMPT = '{"type":"user","message":{"content":"do the thing"}}';
const ASSISTANT_AFTER =
  '{"type":"assistant","message":{"content":[{"type":"text","text":"the fresh answer"}]}}';

function transcriptFile(home: string): string {
  return claudeTranscriptPath(home, CWD, SID);
}

function writeTranscript(home: string, content: string): void {
  const p = transcriptFile(home);
  mkdirSync(dirname(p), { recursive: true });
  writeFileSync(p, content);
}

/**
 * A fake tmux that, on `sendEnter`, simulates the worker accepting the prompt:
 * appends the `user_prompt_submit` (so cmdSend confirms) and a `stop` event (so
 * cmdWaitForTurn sees the turn end), and runs an optional `onTurn` hook to grow
 * the transcript.
 */
function respondingTmux(eventFile: string, onTurn?: () => void): Tmux {
  let responded = false;
  return {
    async hasSession() {
      return true;
    },
    async killSession() {},
    async capturePane() {
      return '';
    },
    async capturePaneFull() {
      return '';
    },
    async sendText() {},
    async sendEnter() {
      if (responded) return;
      responded = true;
      appendEvent(eventFile, {
        event: 'user_prompt_submit',
        ts: '2025-01-01T00:00:01Z',
      });
      appendEvent(eventFile, { event: 'stop', ts: '2025-01-01T00:00:02Z' });
      onTurn?.();
    },
    async sendKey() {},
    async newSession() {},
    async respawnPane() {},
  };
}

function deadTmux(): Tmux {
  return {
    async hasSession() {
      return false;
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
    async newSession() {},
    async respawnPane() {},
  };
}

function makeCtx(workerDir: string, home: string, tmux: Tmux): CommandContext {
  return { workerDir, home, tmux, driver: getDriver('claude') };
}

const fastOpts = {
  timeout: 5,
  sendOpts: { submitTimeout: 5, retryInterval: 2, pollMs: 5 },
  waitPollMs: 5,
  postPollCount: 20,
  postPollMs: 5,
};

describe('cmdConverse', () => {
  let workerDir: string;
  let home: string;

  beforeEach(() => {
    workerDir = tmpDir('csd-conv-wd-');
    home = tmpDir('csd-conv-home-');
    writeMeta(workerDir, {
      tmux_name: TMUX_NAME,
      session_id: SID,
      cwd: CWD,
      harness: 'claude',
    });
  });

  afterEach(() => {
    rmSync(workerDir, { recursive: true });
    rmSync(home, { recursive: true });
    delete process.env.CSD_CONVERSE_DIAG_FILE;
  });

  it('returns the last assistant text on the happy path', async () => {
    const ef = eventsPath(workerDir, SID);
    writeTranscript(home, [ASSISTANT_BEFORE, USER_PROMPT].join('\n'));
    const tmux = respondingTmux(ef, () => {
      writeTranscript(
        home,
        [ASSISTANT_BEFORE, USER_PROMPT, ASSISTANT_AFTER].join('\n'),
      );
    });
    const ctx = makeCtx(workerDir, home, tmux);
    const result = await cmdConverse(ctx, SID, 'do the thing', fastOpts);
    expect(result.code).toBe(0);
    expect(result.stdout).toBe('the fresh answer');
  });

  it('--with-turn returns the rendered markdown turn', async () => {
    const ef = eventsPath(workerDir, SID);
    writeTranscript(home, [ASSISTANT_BEFORE, USER_PROMPT].join('\n'));
    const tmux = respondingTmux(ef, () => {
      writeTranscript(
        home,
        [ASSISTANT_BEFORE, USER_PROMPT, ASSISTANT_AFTER].join('\n'),
      );
    });
    const ctx = makeCtx(workerDir, home, tmux);
    const result = await cmdConverse(ctx, SID, 'do the thing', {
      ...fastOpts,
      withTurn: true,
    });
    expect(result.code).toBe(0);
    expect(result.stdout).toContain('**Prompt:** do the thing');
    expect(result.stdout).toContain('the fresh answer');
  });

  it('reaches the reply when send had to queue the prompt', async () => {
    const ef = eventsPath(workerDir, SID);
    // Worker mid-turn: send can only queue, and returns 0 with a note. The
    // queued turn emits no events of its own — one `stop` closes both turns —
    // so converse must still get there off that shared turn-end.
    appendEvent(ef, {
      event: 'user_prompt_submit',
      ts: '2025-01-01T00:00:00Z',
    });
    appendEvent(ef, {
      event: 'pre_tool_use',
      ts: '2025-01-01T00:00:01Z',
      tool: 'Bash',
      tool_input: { command: 'ping -c 45 127.0.0.1' },
    });
    writeTranscript(home, [EARLIER_PROMPT, ASSISTANT_BEFORE].join('\n'));

    let scheduled = false;
    const timers: NodeJS.Timeout[] = [];
    const tmux: Tmux = {
      async hasSession() {
        return true;
      },
      async killSession() {},
      async capturePane() {
        return '';
      },
      async capturePaneFull() {
        return '';
      },
      async sendText() {},
      async sendEnter() {
        if (scheduled) return;
        scheduled = true;
        // No user_prompt_submit for the queued prompt: it just runs, and a
        // single stop lands once the worker finally goes idle.
        timers.push(
          setTimeout(() => {
            writeTranscript(
              home,
              [
                EARLIER_PROMPT,
                ASSISTANT_BEFORE,
                USER_PROMPT,
                ASSISTANT_AFTER,
              ].join('\n'),
            );
            appendEvent(ef, { event: 'stop', ts: '2025-01-01T00:00:04Z' });
          }, 120),
        );
      },
      async sendKey() {},
      async newSession() {},
      async respawnPane() {},
    };

    const ctx = makeCtx(workerDir, home, tmux);
    try {
      const result = await cmdConverse(ctx, SID, 'do the thing', {
        ...fastOpts,
        sendOpts: { submitTimeout: 0.05, retryInterval: 2, pollMs: 5 },
      });
      expect(result.code).toBe(0);
      expect(result.stdout).toBe('the fresh answer');
    } finally {
      for (const t of timers) clearTimeout(t);
    }
  });

  it('errors when meta has no cwd', async () => {
    const wd = tmpDir('csd-conv-nocwd-');
    writeMeta(wd, {
      tmux_name: 'nc',
      session_id: 'sid-nc',
      cwd: '',
      harness: 'claude',
    });
    const ctx = makeCtx(wd, home, deadTmux());
    const result = await cmdConverse(ctx, 'sid-nc', 'hi', fastOpts);
    expect(result.code).toBe(1);
    expect(result.stderr).toBe(
      'Error: Could not determine working directory from meta file',
    );
    rmSync(wd, { recursive: true });
  });

  it('propagates a send failure (no tmux session)', async () => {
    writeTranscript(home, [ASSISTANT_BEFORE, USER_PROMPT].join('\n'));
    const ctx = makeCtx(workerDir, home, deadTmux());
    const result = await cmdConverse(ctx, SID, 'hi', fastOpts);
    expect(result.code).toBe(1);
    expect(result.stderr).toBe(
      `Error: tmux session '${TMUX_NAME}' does not exist`,
    );
  });

  it('errors and writes a diag file when the turn times out', async () => {
    writeTranscript(home, [ASSISTANT_BEFORE, USER_PROMPT].join('\n'));
    const ef = eventsPath(workerDir, SID);
    // sendEnter confirms submission but never emits a stop, so wait-for-turn
    // times out.
    const tmux: Tmux = {
      async hasSession() {
        return true;
      },
      async killSession() {},
      async capturePane() {
        return '';
      },
      async capturePaneFull() {
        return '';
      },
      async sendText() {},
      async sendEnter() {
        appendEvent(ef, {
          event: 'user_prompt_submit',
          ts: '2025-01-01T00:00:01Z',
        });
      },
      async sendKey() {},
      async newSession() {},
      async respawnPane() {},
    };
    const diagFile = join(home, 'diag.txt');
    process.env.CSD_CONVERSE_DIAG_FILE = diagFile;
    const ctx = makeCtx(workerDir, home, tmux);
    const result = await cmdConverse(ctx, SID, 'hi', {
      ...fastOpts,
      timeout: 0.1,
      now: () => '2026-06-13T00:00:00Z',
      diagRun: async () => ({ stdout: 'PS\n', stderr: '', code: 0 }),
    });
    expect(result.code).toBe(1);
    expect(result.stderr).toContain('Error: Worker did not finish within 0.1s');
    expect(result.stderr).toContain(`csd-diagnostic: ${diagFile}`);
    expect(readFileSync(diagFile, 'utf8')).toContain(
      'reason=wait_for_turn_timeout',
    );
  });

  it('errors and writes a diag when no new assistant text appears', async () => {
    const ef = eventsPath(workerDir, SID);
    // Transcript never grows: turn ends but no new assistant text message.
    writeTranscript(home, [ASSISTANT_BEFORE, USER_PROMPT].join('\n'));
    const tmux = respondingTmux(ef);
    const diagFile = join(home, 'diag.txt');
    process.env.CSD_CONVERSE_DIAG_FILE = diagFile;
    const ctx = makeCtx(workerDir, home, tmux);
    const result = await cmdConverse(ctx, SID, 'hi', {
      ...fastOpts,
      postPollCount: 3,
      postPollMs: 5,
      now: () => '2026-06-13T00:00:00Z',
      diagRun: async () => ({ stdout: 'PS\n', stderr: '', code: 0 }),
    });
    expect(result.code).toBe(1);
    expect(result.stderr).toContain(
      'Error: Timed out waiting for assistant response in session log',
    );
    expect(result.stderr).toContain(`csd-diagnostic: ${diagFile}`);
    expect(readFileSync(diagFile, 'utf8')).toContain(
      'reason=no_assistant_response',
    );
  });
});

// A codex/pi worker registers its transcript_path in the worker meta. The
// driver's transcriptPath reads it back from the GLOBAL worker dir, so these
// tests pin CSD_WORKER_DIR to the test's worker dir. These exercise the
// harness-aware text-extraction path: the count-gate that only recognized the
// claude transcript shape made converse always time out for codex/pi.
describe('cmdConverse — codex/pi harness shapes', () => {
  let workerDir: string;
  let prevWorkerDir: string | undefined;

  function rolloutPath(): string {
    return join(workerDir, 'rollout.jsonl');
  }

  function writeRollout(content: string): void {
    writeFileSync(rolloutPath(), content);
  }

  function registerMeta(harness: string): void {
    writeMeta(workerDir, {
      tmux_name: TMUX_NAME,
      session_id: SID,
      cwd: CWD,
      harness,
      transcript_path: rolloutPath(),
    });
  }

  beforeEach(() => {
    workerDir = tmpDir('csd-conv-hx-');
    prevWorkerDir = process.env.CSD_WORKER_DIR;
    process.env.CSD_WORKER_DIR = workerDir;
  });

  afterEach(() => {
    if (prevWorkerDir === undefined) delete process.env.CSD_WORKER_DIR;
    else process.env.CSD_WORKER_DIR = prevWorkerDir;
    rmSync(workerDir, { recursive: true });
    delete process.env.CSD_CONVERSE_DIAG_FILE;
  });

  const CODEX_USER =
    '{"type":"response_item","payload":{"type":"message","role":"user","content":[{"text":"do the thing"}]}}';
  const CODEX_ASSISTANT =
    '{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"output_text":"codex says hello"}]}}';

  it('returns the codex assistant text (count-gate used to time out)', async () => {
    const ef = eventsPath(workerDir, SID);
    registerMeta('codex');
    writeRollout(CODEX_USER);
    const tmux = respondingTmux(ef, () => {
      writeRollout([CODEX_USER, CODEX_ASSISTANT].join('\n'));
    });
    const ctx: CommandContext = {
      workerDir,
      home: workerDir,
      tmux,
      driver: getDriver('codex'),
    };
    const result = await cmdConverse(ctx, SID, 'do the thing', fastOpts);
    expect(result.code).toBe(0);
    expect(result.stdout).toBe('codex says hello');
  });

  it('--with-turn renders the codex markdown turn', async () => {
    const ef = eventsPath(workerDir, SID);
    registerMeta('codex');
    writeRollout(CODEX_USER);
    const tmux = respondingTmux(ef, () => {
      writeRollout([CODEX_USER, CODEX_ASSISTANT].join('\n'));
    });
    const ctx: CommandContext = {
      workerDir,
      home: workerDir,
      tmux,
      driver: getDriver('codex'),
    };
    const result = await cmdConverse(ctx, SID, 'do the thing', {
      ...fastOpts,
      withTurn: true,
    });
    expect(result.code).toBe(0);
    expect(result.stdout).toContain('**Prompt:** do the thing');
    expect(result.stdout).toContain('codex says hello');
  });

  const PI_HEADER = '{"type":"session","version":3,"id":"s","cwd":"/p"}';
  const PI_USER =
    '{"type":"message","message":{"role":"user","content":"do it"}}';
  const PI_ASSISTANT =
    '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"pi replies"}]}}';

  it('returns the pi assistant text (count-gate used to time out)', async () => {
    const ef = eventsPath(workerDir, SID);
    registerMeta('pi');
    writeRollout([PI_HEADER, PI_USER].join('\n'));
    const tmux = respondingTmux(ef, () => {
      writeRollout([PI_HEADER, PI_USER, PI_ASSISTANT].join('\n'));
    });
    const ctx: CommandContext = {
      workerDir,
      home: workerDir,
      tmux,
      driver: getDriver('pi'),
    };
    const result = await cmdConverse(ctx, SID, 'do it', fastOpts);
    expect(result.code).toBe(0);
    expect(result.stdout).toBe('pi replies');
  });

  it('first converse to a fresh derive worker (no meta yet) sends by tmux name, then resolves', async () => {
    // A fresh codex worker: NO <sid>.meta exists, so it can only be addressed by
    // tmux_name. cmdConverse must NOT fail `no worker known` up front — it sends
    // first (which self-registers the meta like codex's SessionStart hook), then
    // resolves and returns the reply.
    const ef = eventsPath(workerDir, SID);
    const tmux = respondingTmux(ef, () => {
      // The codex hook self-registers the meta on the first prompt.
      registerMeta('codex');
      writeRollout([CODEX_USER, CODEX_ASSISTANT].join('\n'));
    });
    const ctx: CommandContext = {
      workerDir,
      home: workerDir,
      tmux,
      driver: getDriver('codex'),
    };
    // Addressed by TMUX_NAME (no sid known yet).
    const result = await cmdConverse(ctx, TMUX_NAME, 'do the thing', {
      ...fastOpts,
      sendOpts: {
        ...fastOpts.sendOpts,
        registerTimeout: 5,
        registerPollMs: 5,
      },
    });
    expect(result.code).toBe(0);
    expect(result.stdout).toBe('codex says hello');
  });
});
