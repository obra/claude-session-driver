import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { readJsonl } from './helpers/read-jsonl.js';

const FIXTURES = join(dirname(fileURLToPath(import.meta.url)), 'fixtures');
const TRANSCRIPTS = join(FIXTURES, 'claude-transcripts');

function jsonFixture(relative: string): Record<string, unknown> {
  return JSON.parse(readFileSync(join(FIXTURES, relative), 'utf8')) as Record<
    string,
    unknown
  >;
}

describe('terminal-evidence fixtures', () => {
  it('freezes the documented StopFailure payload shape', () => {
    const payload = jsonFixture('hooks/stop-failure.json');
    expect(payload).toMatchObject({
      hook_event_name: 'StopFailure',
      prompt_id: '77777777-7777-4777-8777-777777777777',
      error: 'rate_limit',
      error_details: '429 Too Many Requests',
      last_assistant_message: 'API Error: Rate limit reached',
    });
    expect(payload.transcript_path).toEqual(expect.any(String));
  });

  it('freezes the documented rich Stop payload shape', () => {
    const payload = jsonFixture('hooks/stop-with-background-work.json');
    expect(payload).toMatchObject({
      hook_event_name: 'Stop',
      stop_hook_active: true,
      background_tasks: [{ id: 'task-001', type: 'shell', status: 'running' }],
      session_crons: [
        { id: 'cron-001', schedule: '0 9 * * 1-5', recurring: true },
      ],
    });
  });

  it('retains a structurally marked empirical API-error tail', () => {
    const fixture = join(TRANSCRIPTS, 'response-stopped-arriving.jsonl');
    const { records, malformed } = readJsonl(fixture);
    expect(malformed).toEqual([]);
    expect(records).toHaveLength(3);
    expect(records[1]).toMatchObject({
      type: 'assistant',
      parentUuid: '11111111-1111-4111-8111-111111111111',
      isApiErrorMessage: true,
      version: '2.1.247',
      message: { role: 'assistant' },
    });
  });

  it('retains the measured incomplete tool-use tail without inventing a marker', () => {
    const fixture = join(TRANSCRIPTS, 'interrupted.jsonl');
    const { records, malformed } = readJsonl(fixture);
    expect(malformed).toEqual([]);
    expect(records).toHaveLength(3);
    expect(records.at(-1)).toMatchObject({
      type: 'assistant',
      parentUuid: '55555555-5555-4555-8555-555555555555',
      version: '2.1.247',
      message: {
        role: 'assistant',
        stop_reason: 'tool_use',
        content: [{ type: 'tool_use', name: 'Bash' }],
      },
    });
    expect(records.at(-1)).not.toHaveProperty('isApiErrorMessage');
  });

  it('contains no private paths, prompts, credentials, or tool inputs', () => {
    for (const name of [
      'response-stopped-arriving.jsonl',
      'interrupted.jsonl',
    ]) {
      const text = readFileSync(join(TRANSCRIPTS, name), 'utf8');
      expect(text).not.toMatch(/\/Users\/jzhao268/i);
      expect(text).not.toMatch(/Inspect this directory read-only/i);
      expect(text).not.toMatch(/"input"\s*:/i);
      expect(text).not.toMatch(
        /(?:api[_-]?key|authorization|bearer|credential|signature|token)/i,
      );

      const { records } = readJsonl(join(TRANSCRIPTS, name));
      for (const record of records) {
        const object = record as { type?: unknown; message?: unknown };
        if (object.type !== 'user') continue;
        const message = object.message as { content?: unknown };
        expect(message.content).toBe('<redacted>');
      }
    }
  });

  it('reports malformed JSONL instead of silently dropping it', () => {
    const fixture = join(TRANSCRIPTS, 'interrupted.jsonl');
    const malformedCopy = `${readFileSync(fixture, 'utf8')}not-json\n`;
    const scratchDir = mkdtempSync(join(tmpdir(), 'csd-jsonl-helper-'));
    const scratch = join(scratchDir, 'malformed.jsonl');

    // Exercise the helper through an injectable-looking real file while keeping
    // the committed fixture immutable. The cleanup lives in a finally block so
    // a failed assertion does not leave test state behind.
    writeFileSync(scratch, malformedCopy);
    try {
      expect(readJsonl(scratch).malformed).toEqual([
        { line: 4, text: 'not-json' },
      ]);
    } finally {
      rmSync(scratchDir, { recursive: true, force: true });
    }
  });
});
