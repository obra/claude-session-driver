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
import { cmdWaitForTurn } from '../src/commands/wait-for-turn.js';
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

const ASSISTANT_BEFORE =
  '{"type":"assistant","message":{"content":[{"type":"text","text":"earlier reply"}]}}';
const USER_PROMPT = '{"type":"user","message":{"content":"do the thing"}}';
const ASSISTANT_AFTER =
  '{"type":"assistant","message":{"content":[{"type":"text","text":"the fresh answer"}]}}';
const UUID_ANCHOR =
  '{"type":"assistant","uuid":"99999999-9999-4999-8999-999999999999","message":{"role":"assistant","content":[{"type":"text","text":"earlier reply"}]}}';

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

  it('returns code 3 with exact StopFailure evidence on stderr', async () => {
    const ef = eventsPath(workerDir, SID);
    writeTranscript(home, [ASSISTANT_BEFORE, USER_PROMPT].join('\n'));
    let responded = false;
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
        if (responded) return;
        responded = true;
        appendEvent(ef, {
          event: 'user_prompt_submit',
          ts: '2025-01-01T00:00:01Z',
        });
        appendEvent(ef, {
          event: 'stop_failure',
          ts: '2025-01-01T00:00:02Z',
          prompt_id: 'prompt-1',
          transcript_path: transcriptFile(home),
          error: 'model_not_found',
          error_details: 'unknown model fixture-model',
          last_assistant_message: 'API Error: Model not found',
        });
      },
      async sendKey() {},
      async newSession() {},
      async respawnPane() {},
    };
    const result = await cmdConverse(
      makeCtx(workerDir, home, tmux),
      SID,
      'hi',
      fastOpts,
    );
    expect(result.code).toBe(3);
    expect(result.stdout).toBeUndefined();
    expect(result.stderr).toContain(`worker: ${TMUX_NAME}`);
    expect(result.stderr).toContain(`session_id: ${SID}`);
    expect(result.stderr).toContain('error: model_not_found');
    expect(result.stderr).toContain(
      'error_details: unknown model fixture-model',
    );
    expect(result.stderr).toContain(
      'last_assistant_message: API Error: Model not found',
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
    expect(result.code).toBe(124);
    expect(result.stderr).toContain('Error: Worker did not finish within 0.1s');
    expect(result.stderr).toContain(`worker: ${TMUX_NAME}`);
    expect(result.stderr).toContain(`session_id: ${SID}`);
    expect(result.stderr).toContain(`transcript: ${transcriptFile(home)}`);
    expect(result.stderr).toContain(`events: ${ef}`);
    const cursorMatch = result.stderr?.match(/retry_after_line: (\d+)/);
    expect(cursorMatch).not.toBeNull();
    const cursor = Number(cursorMatch?.[1]);
    expect(result.stderr).toContain(
      `retry: ${join(workerDir, 'bin', TMUX_NAME)} wait-for-turn --after-line ${cursor}`,
    );
    expect(result.stderr).toContain('worker remains reusable');
    expect(result.stderr).toContain(`csd-diagnostic: ${diagFile}`);
    expect(readFileSync(diagFile, 'utf8')).toContain(
      'reason=wait_for_turn_timeout',
    );

    // A terminal event that lands after converse's timeout remains observable
    // through the public retry cursor printed above. A bare wait would baseline
    // after this event and miss it.
    appendEvent(ef, { event: 'stop', ts: '2025-01-01T00:00:02Z' });
    const retry = await cmdWaitForTurn(ctx, SID, {
      timeout: 1,
      pollMs: 5,
      afterLine: cursor,
    });
    expect(retry.code).toBe(0);
    expect(retry.stdout).toContain('"event":"stop"');
  });

  it('uses one bounded Claude transcript fallback after event timeout', async () => {
    writeTranscript(home, `${UUID_ANCHOR}\n`);
    const ef = eventsPath(workerDir, SID);
    let responded = false;
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
        if (responded) return;
        responded = true;
        appendEvent(ef, {
          event: 'user_prompt_submit',
          ts: '2025-01-01T00:00:01Z',
        });
        writeTranscript(
          home,
          `${[
            UUID_ANCHOR,
            '{"type":"user","uuid":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","parentUuid":"99999999-9999-4999-8999-999999999999","message":{"role":"user","content":"hi"}}',
            '{"type":"assistant","uuid":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","parentUuid":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","isApiErrorMessage":true,"message":{"role":"assistant","content":[{"type":"text","text":"API Error: transcript fallback fixture"}]}}',
            '{"type":"system","uuid":"cccccccc-cccc-4ccc-8ccc-cccccccccccc","parentUuid":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","subtype":"turn_duration"}',
          ].join('\n')}\n`,
        );
      },
      async sendKey() {},
      async newSession() {},
      async respawnPane() {},
    };
    const result = await cmdConverse(
      makeCtx(workerDir, home, tmux),
      SID,
      'hi',
      { ...fastOpts, timeout: 0.1 },
    );
    expect(result.code).toBe(3);
    expect(result.stdout).toBeUndefined();
    expect(result.stderr).toContain('evidence_source: claude_transcript_tail');
    expect(result.stderr).toContain(`transcript: ${transcriptFile(home)}`);
    expect(result.stderr).toContain(
      'terminal_record_uuid: bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
    );
    expect(result.stderr).toContain(
      'last_assistant_message: API Error: transcript fallback fixture',
    );
  });

  it('does not claim transcript failure when no pre-send anchor exists', async () => {
    writeTranscript(home, '{"type":"last-prompt","leafUuid":null}');
    const ef = eventsPath(workerDir, SID);
    let responded = false;
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
        if (responded) return;
        responded = true;
        appendEvent(ef, {
          event: 'user_prompt_submit',
          ts: '2025-01-01T00:00:01Z',
        });
        writeTranscript(
          home,
          '{"type":"assistant","uuid":"new-error","isApiErrorMessage":true,"message":{"role":"assistant","content":[{"type":"text","text":"must not be attributed"}]}}',
        );
      },
      async sendKey() {},
      async newSession() {},
      async respawnPane() {},
    };
    const result = await cmdConverse(
      makeCtx(workerDir, home, tmux),
      SID,
      'hi',
      { ...fastOpts, timeout: 0.1 },
    );
    expect(result.code).toBe(124);
    expect(result.stderr).not.toContain('evidence_source');
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
