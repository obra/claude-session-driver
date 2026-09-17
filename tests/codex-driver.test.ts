import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { parse as parseToml } from 'smol-toml';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { renderTurn } from '../src/core/transcript.js';
import { codex, codexWorkerEnv } from '../src/harness/codex.js';
import { getDriver } from '../src/harness/registry.js';

describe('registry getDriver(codex)', () => {
  it('returns the codex driver with the expected static fields', () => {
    const d = getDriver('codex');
    expect(d.id).toBe('codex');
    expect(d.idStrategy).toBe('derive');
    expect(d.controlPlane).toBe('hooks');
    expect(d.quitKeys).toBe('/quit');
  });
});

describe('codex.bin', () => {
  it('defaults to "codex"', () => {
    const prev = process.env.CSD_CODEX_BIN;
    delete process.env.CSD_CODEX_BIN;
    try {
      expect(codex.bin()).toBe('codex');
    } finally {
      if (prev !== undefined) process.env.CSD_CODEX_BIN = prev;
    }
  });

  it('honors CSD_CODEX_BIN', () => {
    const prev = process.env.CSD_CODEX_BIN;
    process.env.CSD_CODEX_BIN = '/opt/codex';
    try {
      expect(codex.bin()).toBe('/opt/codex');
    } finally {
      if (prev === undefined) delete process.env.CSD_CODEX_BIN;
      else process.env.CSD_CODEX_BIN = prev;
    }
  });
});

describe('codex.launchArgv', () => {
  it('builds the bypass argv with -C <cwd> and the binary first', () => {
    const argv = codex.launchArgv('launch', 'SID', '/work', '/plug', '/home');
    expect(argv[0]).toBe('codex');
    expect(argv).toContain('--dangerously-bypass-approvals-and-sandbox');
    expect(argv).toContain('--dangerously-bypass-hook-trust');
    const cIdx = argv.indexOf('-C');
    expect(cIdx).toBeGreaterThanOrEqual(0);
    expect(argv[cIdx + 1]).toBe('/work');
  });

  it('ignores mode/sid (codex derives its own id)', () => {
    const launch = codex.launchArgv('launch', 'A', '/work', '/p', '/h');
    const adopt = codex.launchArgv('adopt', 'B', '/work', '/p', '/h');
    expect(launch).toEqual(adopt);
  });

  it('honors CSD_CODEX_BIN as argv[0]', () => {
    const prev = process.env.CSD_CODEX_BIN;
    process.env.CSD_CODEX_BIN = '/opt/codex';
    try {
      expect(codex.launchArgv('launch', 'S', '/c', '/p', '/h')[0]).toBe(
        '/opt/codex',
      );
    } finally {
      if (prev === undefined) delete process.env.CSD_CODEX_BIN;
      else process.env.CSD_CODEX_BIN = prev;
    }
  });
});

describe('codex.workerEnv', () => {
  it('sets CODEX_HOME to the worker home (ignoring tmuxName)', () => {
    expect(codex.workerEnv('/tmp/wh', 'w1', {})).toEqual({
      CODEX_HOME: '/tmp/wh',
    });
  });

  it('delegates to codexWorkerEnv', () => {
    expect(codex.workerEnv('/tmp/wh', 'w1', {})).toEqual(
      codexWorkerEnv('/tmp/wh'),
    );
  });
});

describe('codex.prepare', () => {
  let home: string;
  let codexHome: string;
  let workerDir: string;
  let prevHome: string | undefined;
  let prevWorkerDir: string | undefined;
  let prevEmit: string | undefined;

  beforeEach(() => {
    home = mkdtempSync(join(tmpdir(), 'codex-home-'));
    codexHome = mkdtempSync(join(tmpdir(), 'codex-worker-'));
    workerDir = mkdtempSync(join(tmpdir(), 'codex-wd-'));
    prevHome = process.env.HOME;
    prevWorkerDir = process.env.CSD_WORKER_DIR;
    prevEmit = process.env.CSD_EMIT_EVENT_PATH;
    process.env.HOME = home;
    process.env.CSD_WORKER_DIR = workerDir;
    process.env.CSD_EMIT_EVENT_PATH = '/plug/dist/emit-event.cjs';
  });

  afterEach(() => {
    rmSync(home, { recursive: true, force: true });
    rmSync(codexHome, { recursive: true, force: true });
    rmSync(workerDir, { recursive: true, force: true });
    if (prevHome === undefined) delete process.env.HOME;
    else process.env.HOME = prevHome;
    if (prevWorkerDir === undefined) delete process.env.CSD_WORKER_DIR;
    else process.env.CSD_WORKER_DIR = prevWorkerDir;
    if (prevEmit === undefined) delete process.env.CSD_EMIT_EVENT_PATH;
    else process.env.CSD_EMIT_EVENT_PATH = prevEmit;
  });

  it('writes a valid config.toml with no pinned model, trust, and all six hook events', async () => {
    await codex.prepare('w1', '/some/project', codexHome);
    const raw = readFileSync(join(codexHome, 'config.toml'), 'utf8');
    const parsed = parseToml(raw) as Record<string, unknown>;

    expect(parsed.model).toBeUndefined();
    expect(parsed.model_reasoning_effort).toBe('low');
    expect(
      (parsed.notice as Record<string, unknown>).hide_rate_limit_model_nudge,
    ).toBe(true);

    const projects = parsed.projects as Record<string, { trust_level: string }>;
    expect(projects['/some/project']!.trust_level).toBe('trusted');

    const hooks = parsed.hooks as Record<string, unknown[]>;
    for (const ev of [
      'SessionStart',
      'UserPromptSubmit',
      'PreToolUse',
      'PostToolUse',
      'Stop',
      'SessionEnd',
    ]) {
      expect(Array.isArray(hooks[ev])).toBe(true);
      expect(hooks[ev]!.length).toBe(1);
    }
  });

  it('honors CSD_CODEX_MODEL', async () => {
    const prev = process.env.CSD_CODEX_MODEL;
    process.env.CSD_CODEX_MODEL = 'gpt-6';
    try {
      await codex.prepare('w1', '/proj', codexHome);
      const parsed = parseToml(
        readFileSync(join(codexHome, 'config.toml'), 'utf8'),
      ) as Record<string, unknown>;
      expect(parsed.model).toBe('gpt-6');
    } finally {
      if (prev === undefined) delete process.env.CSD_CODEX_MODEL;
      else process.env.CSD_CODEX_MODEL = prev;
    }
  });

  it('sets matcher=".*" only on PreToolUse/PostToolUse', async () => {
    await codex.prepare('w1', '/proj', codexHome);
    const parsed = parseToml(
      readFileSync(join(codexHome, 'config.toml'), 'utf8'),
    ) as Record<string, unknown>;
    const hooks = parsed.hooks as Record<
      string,
      Array<{
        matcher?: string;
        hooks: Array<{ type: string; command: string }>;
      }>
    >;
    expect(hooks.PreToolUse![0]!.matcher).toBe('.*');
    expect(hooks.PostToolUse![0]!.matcher).toBe('.*');
    expect(hooks.SessionStart![0]!.matcher).toBeUndefined();
    expect(hooks.Stop![0]!.matcher).toBeUndefined();
  });

  it('bakes the emit-event.cjs command with tmux_name, cwd, worker_dir', async () => {
    await codex.prepare('worker-7', '/proj', codexHome);
    const parsed = parseToml(
      readFileSync(join(codexHome, 'config.toml'), 'utf8'),
    ) as Record<string, unknown>;
    const hooks = parsed.hooks as Record<
      string,
      Array<{ hooks: Array<{ type: string; command: string }> }>
    >;
    const cmd = hooks.SessionStart![0]!.hooks[0]!;
    expect(cmd.type).toBe('command');
    expect(cmd.command).toContain('emit-event.cjs');
    expect(cmd.command).toContain('worker-7');
    expect(cmd.command).toContain('/proj');
    expect(cmd.command).toContain(workerDir);
  });

  it('survives a cwd with a space: valid TOML, path round-trips in key AND command', async () => {
    const spaced = join(tmpdir(), 'my worker dir');
    mkdirSync(spaced, { recursive: true });
    try {
      await codex.prepare('w1', spaced, codexHome);
      const raw = readFileSync(join(codexHome, 'config.toml'), 'utf8');
      // Must be valid TOML (smol-toml throws on invalid input).
      const parsed = parseToml(raw) as Record<string, unknown>;

      const projects = parsed.projects as Record<
        string,
        { trust_level: string }
      >;
      // The spaced cwd survives as the exact table key.
      expect(projects[spaced]!.trust_level).toBe('trusted');

      const hooks = parsed.hooks as Record<
        string,
        Array<{ hooks: Array<{ command: string }> }>
      >;
      const cmd = hooks.SessionStart![0]!.hooks[0]!.command;
      // The spaced cwd survives inside the (shell-quoted) command string.
      expect(cmd).toContain(spaced);
      expect(cmd).toContain(workerDir);
    } finally {
      rmSync(spaced, { recursive: true, force: true });
    }
  });

  it('survives a cwd with a double-quote and backslash', async () => {
    const nasty = '/tmp/a"b\\c dir';
    await codex.prepare('w1', nasty, codexHome);
    const raw = readFileSync(join(codexHome, 'config.toml'), 'utf8');
    const parsed = parseToml(raw) as Record<string, unknown>;
    const projects = parsed.projects as Record<string, { trust_level: string }>;
    expect(projects[nasty]!.trust_level).toBe('trusted');
    const hooks = parsed.hooks as Record<
      string,
      Array<{ hooks: Array<{ command: string }> }>
    >;
    expect(hooks.SessionStart![0]!.hooks[0]!.command).toContain(nasty);
  });

  it('stages ~/.codex/auth.json into the worker home when present', async () => {
    mkdirSync(join(home, '.codex'), { recursive: true });
    writeFileSync(join(home, '.codex', 'auth.json'), '{"token":"abc"}');
    await codex.prepare('w1', '/proj', codexHome);
    expect(readFileSync(join(codexHome, 'auth.json'), 'utf8')).toBe(
      '{"token":"abc"}',
    );
  });

  it('does not fail when ~/.codex/auth.json is absent', async () => {
    await expect(
      codex.prepare('w1', '/proj', codexHome),
    ).resolves.not.toThrow();
  });
});

describe('codex.transcriptPath', () => {
  let workerDir: string;
  let prevWorkerDir: string | undefined;

  beforeEach(() => {
    workerDir = mkdtempSync(join(tmpdir(), 'codex-tp-'));
    prevWorkerDir = process.env.CSD_WORKER_DIR;
    process.env.CSD_WORKER_DIR = workerDir;
  });

  afterEach(() => {
    rmSync(workerDir, { recursive: true, force: true });
    if (prevWorkerDir === undefined) delete process.env.CSD_WORKER_DIR;
    else process.env.CSD_WORKER_DIR = prevWorkerDir;
  });

  it('reads transcript_path from the self-registered meta', () => {
    writeFileSync(
      join(workerDir, 'SID.meta'),
      JSON.stringify({ transcript_path: '/x/rollout.jsonl' }),
    );
    expect(codex.transcriptPath('SID', '/proj', '/home')).toBe(
      '/x/rollout.jsonl',
    );
  });

  it('returns empty string when meta is missing or lacks transcript_path', () => {
    expect(codex.transcriptPath('NOPE', '/proj', '/home')).toBe('');
    writeFileSync(join(workerDir, 'NO.meta'), JSON.stringify({ cwd: '/p' }));
    expect(codex.transcriptPath('NO', '/proj', '/home')).toBe('');
  });
});

describe('codex.parseTurn', () => {
  const userMsg = (text: string) =>
    JSON.stringify({
      type: 'response_item',
      payload: { type: 'message', role: 'user', content: [{ text }] },
    });
  const asstMsg = (text: string) =>
    JSON.stringify({
      type: 'response_item',
      payload: {
        type: 'message',
        role: 'assistant',
        content: [{ output_text: text }],
      },
    });
  const reasoning = (text: string) =>
    JSON.stringify({
      type: 'response_item',
      payload: { type: 'reasoning', summary: [{ text }] },
    });
  const fnCall = (name: string, args: unknown) =>
    JSON.stringify({
      type: 'response_item',
      payload: { type: 'function_call', name, arguments: args },
    });
  const fnOut = (output: string) =>
    JSON.stringify({
      type: 'response_item',
      payload: { type: 'function_call_output', output },
    });
  const eventMsg = JSON.stringify({
    type: 'event_msg',
    payload: { type: 'agent_message', message: 'noise' },
  });

  it('parses a full rollout turn into the normalized items', () => {
    const rollout = [
      asstMsg('earlier turn, ignored'),
      userMsg('do the thing'),
      reasoning('let me think'),
      asstMsg('here is my answer'),
      fnCall('shell', { cmd: 'ls' }),
      fnOut('file1\nfile2'),
      eventMsg,
    ].join('\n');

    const turn = codex.parseTurn(rollout);
    expect(turn).toEqual([
      { kind: 'prompt', text: 'do the thing' },
      { kind: 'thinking', text: 'let me think' },
      { kind: 'text', text: 'here is my answer' },
      { kind: 'tool_use', name: 'shell', input: { cmd: 'ls' } },
      { kind: 'tool_result', content: 'file1\nfile2', isError: false },
    ]);
  });

  it('renders the normalized turn with the shared renderer', () => {
    const rollout = [
      userMsg('do it'),
      reasoning('hmm'),
      asstMsg('ok'),
      fnCall('shell', { cmd: 'ls' }),
      fnOut('out'),
    ].join('\n');
    const md = renderTurn(codex.parseTurn(rollout), { full: true });
    expect(md).toContain('**Prompt:** do it');
    expect(md).toContain('> **Thinking:** hmm');
    expect(md).toContain('ok');
    expect(md).toContain('**Tool: shell**');
    expect(md).toContain('**Result:**');
    expect(md).toContain('out');
  });

  it('starts from line 1 when there is no user message', () => {
    const rollout = [asstMsg('hello'), fnCall('shell', { cmd: 'ls' })].join(
      '\n',
    );
    const turn = codex.parseTurn(rollout);
    expect(turn).toEqual([
      { kind: 'text', text: 'hello' },
      { kind: 'tool_use', name: 'shell', input: { cmd: 'ls' } },
    ]);
  });

  it('skips malformed and non-object lines without throwing', () => {
    const rollout = [
      'not json at all',
      '42',
      'null',
      userMsg('go'),
      '{"type":"response_item"}',
      asstMsg('done'),
    ].join('\n');
    const turn = codex.parseTurn(rollout);
    expect(turn).toEqual([
      { kind: 'prompt', text: 'go' },
      { kind: 'text', text: 'done' },
    ]);
  });

  it('passes a string arguments value through to tool_use input', () => {
    const rollout = [userMsg('go'), fnCall('shell', '{"cmd":"ls"}')].join('\n');
    const turn = codex.parseTurn(rollout);
    expect(turn).toEqual([
      { kind: 'prompt', text: 'go' },
      { kind: 'tool_use', name: 'shell', input: '{"cmd":"ls"}' },
    ]);
  });

  it('returns an empty turn for empty input', () => {
    expect(codex.parseTurn('')).toEqual([]);
  });
});
