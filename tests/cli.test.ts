import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { Readable } from 'node:stream';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import {
  followStream,
  grantConsentConfirm,
  grantWorkspaceTrustConfirm,
  readExactLine,
  readLine,
  run,
} from '../src/cli.js';
import type { CommandContext } from '../src/commands/context.js';
import { appendEvent } from '../src/core/event-log.js';
import { claudeTranscriptPath, eventsPath } from '../src/core/paths.js';
import { makeTmux } from '../src/core/tmux.js';
import { writeMeta } from '../src/core/worker-store.js';
import { getDriver } from '../src/harness/registry.js';

/** Capture stdout/stderr that `run` would write. */
function makeIo() {
  const out: string[] = [];
  const err: string[] = [];
  return {
    io: { out: (s: string) => out.push(s), err: (s: string) => err.push(s) },
    out: () => out.join(''),
    err: () => err.join(''),
  };
}

describe('run — validation and dispatch', () => {
  let workerDir: string;
  let prevWorkerDir: string | undefined;

  beforeEach(() => {
    workerDir = mkdtempSync(join(tmpdir(), 'csd-cli-'));
    prevWorkerDir = process.env.CSD_WORKER_DIR;
    process.env.CSD_WORKER_DIR = workerDir;
  });

  afterEach(() => {
    if (prevWorkerDir === undefined) {
      delete process.env.CSD_WORKER_DIR;
    } else {
      process.env.CSD_WORKER_DIR = prevWorkerDir;
    }
    rmSync(workerDir, { recursive: true, force: true });
  });

  it('rejects --worker for a top-level subcommand', async () => {
    const { io, err } = makeIo();
    const code = await run(['--worker', 'w', 'launch'], io);
    expect(code).toBe(2);
    expect(err()).toContain(
      "Error: --worker is not valid for 'launch' (top-level subcommand)",
    );
  });

  it('requires --worker for a per-worker subcommand', async () => {
    const { io, err } = makeIo();
    const code = await run(['status'], io);
    expect(code).toBe(2);
    expect(err()).toContain("Error: --worker <name> is required for 'status'");
  });

  it('errors when --worker has no value', async () => {
    const { io, err } = makeIo();
    const code = await run(['--worker'], io);
    expect(code).toBe(2);
    expect(err()).toContain('Error: --worker requires a value');
  });

  it('rejects an empty send prompt up front, not after the submit timeout (RE-3)', async () => {
    const { io, err } = makeIo();
    const code = await run(['--worker', 'w', 'send', ''], io);
    expect(code).toBe(2);
    expect(err()).toContain('Usage: send');
  });

  it('rejects an empty converse prompt up front (RE-3)', async () => {
    const { io, err } = makeIo();
    const code = await run(['--worker', 'w', 'converse', ''], io);
    expect(code).toBe(2);
    expect(err()).toContain('Usage: converse');
  });

  it('rejects an unknown subcommand with usage', async () => {
    const { io, err } = makeIo();
    const code = await run(['bogus'], io);
    expect(code).toBe(2);
    expect(err()).toContain("Error: unknown subcommand 'bogus'");
    expect(err()).toContain('Usage: csd <subcommand>');
  });

  it('prints usage to stderr when no subcommand is given', async () => {
    const { io, err, out } = makeIo();
    const code = await run([], io);
    expect(code).toBe(2);
    expect(err()).toContain('Usage: csd <subcommand>');
    expect(out()).toBe('');
  });

  it('prints usage to stdout for help (code 0)', async () => {
    const { io, out, err } = makeIo();
    const code = await run(['help'], io);
    expect(code).toBe(0);
    expect(out()).toContain('Usage: csd <subcommand>');
    expect(err()).toBe('');
  });

  it('usage text references the new /tmp/csd-workers default and lists subcommands', async () => {
    const { io, out } = makeIo();
    await run(['help'], io);
    const usage = out();
    expect(usage).toContain('/tmp/csd-workers');
    expect(usage).not.toContain('/tmp/claude-workers');
    for (const sub of [
      'launch',
      'adopt',
      'list',
      'grant-consent',
      'grant-workspace-trust',
      'converse',
      'send',
      'wait-for-turn',
      'status',
      'read-events',
      'read-turn',
      'stop',
      'handoff',
      'session-id',
      'events-file',
    ]) {
      expect(usage).toContain(sub);
    }
  });

  it('dispatches list to cmdList (no workers) via ctx wiring', async () => {
    const { io, err, out } = makeIo();
    const code = await run(['list'], io);
    expect(code).toBe(0);
    expect(err()).toContain('No workers found');
    expect(out()).toBe('');
  });

  it('dispatches status to cmdStatus and returns its code for an unknown worker', async () => {
    const { io, err } = makeIo();
    const code = await run(['--worker', 'nope', 'status'], io);
    expect(code).toBe(1);
    expect(err()).toContain("Error: no worker known as 'nope'");
  });

  it('reports a usage error for launch missing positionals', async () => {
    const { io, err } = makeIo();
    const code = await run(['launch'], io);
    expect(code).toBe(2);
    expect(err()).toContain(
      'Usage: launch <tmux-name> <cwd> [-- claude-args...]',
    );
  });

  it('reports a usage error for adopt missing positionals', async () => {
    const { io, err } = makeIo();
    const code = await run(['adopt', 'name'], io);
    expect(code).toBe(2);
    expect(err()).toContain(
      'Usage: adopt <tmux-name> <cwd> <session-id> [-- claude-args...]',
    );
  });

  it('requires exactly one cwd for grant-workspace-trust', async () => {
    for (const argv of [
      ['grant-workspace-trust'],
      ['grant-workspace-trust', '/one', '/two'],
    ]) {
      const { io, err } = makeIo();
      const code = await run(argv, io);
      expect(code).toBe(2);
      expect(err()).toContain('Usage: grant-workspace-trust <cwd>');
    }
  });

  it('rejects unknown options for list', async () => {
    const { io, err } = makeIo();
    const code = await run(['list', '--bogus'], io);
    expect(code).toBe(2);
    expect(err()).toContain("Error: unknown option '--bogus' for list");
  });

  it('rejects more than one pattern for list', async () => {
    const { io, err } = makeIo();
    const code = await run(['list', 'a', 'b'], io);
    expect(code).toBe(2);
    expect(err()).toContain('Error: list takes at most one pattern argument');
  });

  it('rejects unknown options for read-events', async () => {
    const { io, err } = makeIo();
    const code = await run(['--worker', 'w', 'read-events', '--bogus'], io);
    expect(code).toBe(2);
    expect(err()).toContain("Error: unknown option '--bogus' for read-events");
  });

  it('rejects unknown options for wait-for-turn', async () => {
    const { io, err } = makeIo();
    const code = await run(['--worker', 'w', 'wait-for-turn', '--bogus'], io);
    expect(code).toBe(2);
    expect(err()).toContain(
      "Error: unknown option '--bogus' for wait-for-turn",
    );
  });

  it('requires a prompt for converse (return 2)', async () => {
    const { io, err } = makeIo();
    const code = await run(['--worker', 'w', 'converse'], io);
    expect(code).toBe(2);
    expect(err()).toContain(
      'Usage: converse [--with-turn] <prompt> [timeout=120]',
    );
  });

  it('requires a prompt for send (return 2)', async () => {
    const { io, err } = makeIo();
    const code = await run(['--worker', 'w', 'send'], io);
    expect(code).toBe(2);
    expect(err()).toContain('Usage: send <prompt-text>');
  });

  it('accepts --worker=value form', async () => {
    const { io, err } = makeIo();
    const code = await run(['--worker=nope', 'status'], io);
    expect(code).toBe(1);
    expect(err()).toContain("Error: no worker known as 'nope'");
  });

  it('treats an empty --worker= as missing (bash -z), not as worker ""', async () => {
    const { io, err } = makeIo();
    const code = await run(['--worker=', 'status'], io);
    // bash: [ -z "$WORKER" ] -> required -> exit 2, NOT exit 1 "no worker '' "
    expect(code).toBe(2);
    expect(err()).toContain("Error: --worker <name> is required for 'status'");
    expect(err()).not.toContain("no worker known as ''");
  });

  it('rejects read-events --last with no value (would otherwise be NaN → all lines)', async () => {
    const { io, err } = makeIo();
    const code = await run(['--worker', 'w', 'read-events', '--last'], io);
    expect(code).toBe(2);
    expect(err()).toContain('Error: --last expects a number for read-events');
  });

  it('rejects read-events --type swallowing a following flag (--type --follow)', async () => {
    const { io, err } = makeIo();
    const code = await run(
      ['--worker', 'w', 'read-events', '--type', '--follow'],
      io,
    );
    expect(code).toBe(2);
    expect(err()).toContain('Error: --type expects a value for read-events');
  });

  it('rejects wait-for-turn --after-line with no value', async () => {
    const { io, err } = makeIo();
    const code = await run(
      ['--worker', 'w', 'wait-for-turn', '--after-line'],
      io,
    );
    expect(code).toBe(2);
    expect(err()).toContain(
      'Error: --after-line expects a number for wait-for-turn',
    );
  });

  it('prints a reusable --after-line cursor on wait-for-turn exit 124', async () => {
    const sid = 'sid-wait-cursor';
    writeMeta(workerDir, {
      tmux_name: 'wait-cursor-worker',
      session_id: sid,
      cwd: '/home/user/project',
      harness: 'claude',
    });
    const ef = eventsPath(workerDir, sid);
    appendEvent(ef, { event: 'session_start', ts: 'T1' });
    appendEvent(ef, { event: 'user_prompt_submit', ts: 'T2' });

    const { io, err } = makeIo();
    const code = await run(
      ['--worker', sid, 'wait-for-turn', '0', '--after-line', '2'],
      io,
    );
    expect(code).toBe(124);
    expect(err()).toContain('retry_after_line: 2');
    expect(err()).toContain('wait-for-turn --after-line 2');
  });

  it('rejects converse with a non-numeric timeout positional', async () => {
    const { io, err } = makeIo();
    const code = await run(
      ['--worker', 'w', 'converse', 'hello', 'notanumber'],
      io,
    );
    expect(code).toBe(2);
    expect(err()).toContain('Error: converse timeout must be a number');
  });

  it('rejects launch --harness bogus with a clean code-2 message (not a stack trace)', async () => {
    const { io, err } = makeIo();
    const tmpCwd = mkdtempSync(join(tmpdir(), 'csd-cwd-'));
    try {
      const code = await run(['launch', 'x', tmpCwd, '--harness', 'bogus'], io);
      expect(code).toBe(2);
      expect(err()).toContain("Unknown harness 'bogus'");
      expect(err()).toContain('Available: claude');
    } finally {
      rmSync(tmpCwd, { recursive: true, force: true });
    }
  });

  it('uses send <prompt-text> in the missing-prompt message (bash parity)', async () => {
    const { io, err } = makeIo();
    const code = await run(['--worker', 'w', 'send'], io);
    expect(code).toBe(2);
    expect(err()).toContain('Usage: send <prompt-text>');
  });

  it('documents the complete public exit-code table', async () => {
    const { io, out } = makeIo();
    await run(['help'], io);
    for (const entry of [
      '0   Success',
      '1   Operational error',
      '2   CLI usage error',
      '3   Proven API-error turn',
      '4   Reserved for interruption',
      '124 Wait budget expired',
    ]) {
      expect(out()).toContain(entry);
    }
  });
});

describe('read-turn — trailing newline parity (bash: exactly two)', () => {
  let workerDir: string;
  let home: string;
  let prevWorkerDir: string | undefined;
  let prevHome: string | undefined;
  const SID = 'sid-rt-nl';
  const CWD = '/home/user/project';

  beforeEach(() => {
    workerDir = mkdtempSync(join(tmpdir(), 'csd-rtnl-wd-'));
    home = mkdtempSync(join(tmpdir(), 'csd-rtnl-home-'));
    prevWorkerDir = process.env.CSD_WORKER_DIR;
    prevHome = process.env.HOME;
    process.env.CSD_WORKER_DIR = workerDir;
    process.env.HOME = home;
    writeMeta(workerDir, {
      tmux_name: 'rtnl-worker',
      session_id: SID,
      cwd: CWD,
      harness: 'claude',
    });
    const transcript = [
      '{"type":"user","message":{"content":"do it"}}',
      '{"type":"assistant","message":{"content":[{"type":"text","text":"ok"}]}}',
    ].join('\n');
    const p = claudeTranscriptPath(home, CWD, SID);
    mkdirSync(dirname(p), { recursive: true });
    writeFileSync(p, transcript);
  });

  afterEach(() => {
    if (prevWorkerDir === undefined) delete process.env.CSD_WORKER_DIR;
    else process.env.CSD_WORKER_DIR = prevWorkerDir;
    if (prevHome === undefined) delete process.env.HOME;
    else process.env.HOME = prevHome;
    rmSync(workerDir, { recursive: true, force: true });
    rmSync(home, { recursive: true, force: true });
  });

  it('emits exactly two trailing newlines, not three', async () => {
    const { io, out } = makeIo();
    const code = await run(['--worker', SID, 'read-turn'], io);
    expect(code).toBe(0);
    const text = out();
    expect(text.endsWith('ok\n\n')).toBe(true);
    expect(text.endsWith('\n\n\n')).toBe(false);
  });
});

describe('readLine — piped (non-TTY) stdin', () => {
  it('returns the first piped line (the close-races-line bug denied consent)', async () => {
    const reply = await readLine(Readable.from('yes\n'));
    expect(reply).toBe('yes');
  });

  it('trims the piped line', async () => {
    const reply = await readLine(Readable.from('  yes  \n'));
    expect(reply).toBe('yes');
  });

  it('resolves empty string on an empty pipe (no line, just EOF)', async () => {
    const reply = await readLine(Readable.from(''));
    expect(reply).toBe('');
  });

  it('returns a non-yes piped line verbatim', async () => {
    const reply = await readLine(Readable.from('no\n'));
    expect(reply).toBe('no');
  });
});

describe('readExactLine — workspace path confirmation', () => {
  it('preserves the complete line without trimming path characters', async () => {
    expect(await readExactLine(Readable.from('  /path with spaces  \n'))).toBe(
      '  /path with spaces  ',
    );
  });

  it('prints the exact-path prompt before reading', async () => {
    const { io, out } = makeIo();
    const answer = await grantWorkspaceTrustConfirm(
      io,
      Readable.from('/canonical/path\n'),
    );
    expect(answer).toBe('/canonical/path');
    expect(out()).toContain('Type the exact canonical path');
  });
});

describe('grantConsentConfirm — piped (non-TTY) stdin', () => {
  function makeIo() {
    const out: string[] = [];
    return {
      io: { out: (s: string) => out.push(s), err: () => {} },
      out: () => out.join(''),
    };
  }

  it("grants when 'yes' is piped (echo yes | csd grant-consent)", async () => {
    const { io } = makeIo();
    const granted = await grantConsentConfirm(io, Readable.from('yes\n'));
    expect(granted).toBe(true);
  });

  it("denies when 'no' is piped", async () => {
    const { io } = makeIo();
    const granted = await grantConsentConfirm(io, Readable.from('no\n'));
    expect(granted).toBe(false);
  });

  it('denies on an empty pipe', async () => {
    const { io } = makeIo();
    const granted = await grantConsentConfirm(io, Readable.from(''));
    expect(granted).toBe(false);
  });

  it('prints the prompt before reading', async () => {
    const { io, out } = makeIo();
    await grantConsentConfirm(io, Readable.from('yes\n'));
    expect(out()).toContain("Type 'yes' to grant consent:");
  });
});

describe('followStream — the --follow streaming sink', () => {
  let workerDir: string;

  function makeCtx(): CommandContext {
    return {
      workerDir,
      home: workerDir,
      tmux: makeTmux(async () => ({ stdout: '', stderr: '', code: 0 })),
      driver: getDriver('claude'),
    };
  }

  beforeEach(() => {
    workerDir = mkdtempSync(join(tmpdir(), 'csd-follow-'));
    writeMeta(workerDir, {
      tmux_name: 'follow-worker',
      session_id: 'sid-follow',
      cwd: '/home/user/project',
      harness: 'claude',
    });
  });

  afterEach(() => {
    rmSync(workerDir, { recursive: true, force: true });
  });

  it('delivers newline-terminated lines to io.out, then resolves 0 on abort', async () => {
    const out: string[] = [];
    const io = { out: (s: string) => out.push(s), err: () => {} };
    const ef = eventsPath(workerDir, 'sid-follow');
    appendEvent(ef, { event: 'session_start', ts: '2025-01-01T00:00:00Z' });

    const ctrl = new AbortController();
    const done = followStream(
      makeCtx(),
      'sid-follow',
      { pollMs: 5 },
      io,
      ctrl.signal,
    );

    // Give the poll loop a moment, then append a fresh line.
    await new Promise((r) => setTimeout(r, 20));
    appendEvent(ef, { event: 'stop', ts: '2025-01-01T00:00:01Z' });
    await new Promise((r) => setTimeout(r, 20));
    ctrl.abort();

    const code = await done;
    expect(code).toBe(0);
    // The sink appends a trailing newline to each emitted raw line.
    expect(out).toContain(
      '{"event":"session_start","ts":"2025-01-01T00:00:00Z"}\n',
    );
    expect(out).toContain('{"event":"stop","ts":"2025-01-01T00:00:01Z"}\n');
    for (const chunk of out) {
      expect(chunk.endsWith('\n')).toBe(true);
    }
  });
});
