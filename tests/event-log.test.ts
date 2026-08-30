import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { classifyStatus, readRawLines } from '../src/core/event-log.js';
import type { WorkerEvent } from '../src/events.js';

describe('readRawLines', () => {
  let dir: string;
  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), 'csd-el-'));
  });
  afterEach(() => {
    rmSync(dir, { recursive: true });
  });

  it('returns [] for a missing file', () => {
    expect(readRawLines(join(dir, 'no-such-file.jsonl'))).toEqual([]);
  });

  it('returns non-empty lines from a file', () => {
    const file = join(dir, 'events.jsonl');
    writeFileSync(file, '{"event":"stop"}\n{"event":"session_end"}\n');
    expect(readRawLines(file)).toEqual([
      '{"event":"stop"}',
      '{"event":"session_end"}',
    ]);
  });

  it('drops empty lines', () => {
    const file = join(dir, 'events.jsonl');
    writeFileSync(file, '{"event":"stop"}\n\n{"event":"session_end"}\n\n');
    expect(readRawLines(file)).toEqual([
      '{"event":"stop"}',
      '{"event":"session_end"}',
    ]);
  });
});

const ev = (event: WorkerEvent['event']): WorkerEvent =>
  (event === 'pre_tool_use'
    ? { event, ts: 'T', tool: 'Bash', tool_input: {} }
    : event === 'post_tool_use'
      ? { event, ts: 'T', tool: 'Bash' }
      : { event, ts: 'T' }) as WorkerEvent;

describe('classifyStatus', () => {
  it('working for prompt/pre/post tool use', () => {
    for (const e of [
      'user_prompt_submit',
      'pre_tool_use',
      'post_tool_use',
    ] as const)
      expect(classifyStatus(ev(e))).toBe('working');
  });
  it('idle for stop/session_start', () => {
    expect(classifyStatus(ev('stop'))).toBe('idle');
    expect(classifyStatus(ev('stop_failure'))).toBe('idle');
    expect(classifyStatus(ev('session_start'))).toBe('idle');
  });
  it('terminated for session_end', () => {
    expect(classifyStatus(ev('session_end'))).toBe('terminated');
  });
});
