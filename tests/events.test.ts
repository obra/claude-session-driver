import { describe, expect, it } from 'vitest';
import { parseEvent, serializeEvent, type WorkerEvent } from '../src/events.js';

describe('events', () => {
  it('round-trips a pre_tool_use event', () => {
    const e: WorkerEvent = {
      event: 'pre_tool_use',
      ts: 'T',
      tool: 'Bash',
      tool_input: { cmd: 'ls' },
    };
    expect(parseEvent(serializeEvent(e))).toEqual(e);
  });
  it('parses a session_start with cwd', () => {
    expect(parseEvent('{"event":"session_start","ts":"T","cwd":"/x"}')).toEqual(
      {
        event: 'session_start',
        ts: 'T',
        cwd: '/x',
      },
    );
  });
  it('round-trips terminal events with structured evidence', () => {
    const failed: WorkerEvent = {
      event: 'stop_failure',
      ts: 'T',
      prompt_id: 'prompt-1',
      transcript_path: '/tmp/transcript.jsonl',
      error: 'future_provider_error',
      error_details: 'opaque details',
      last_assistant_message: 'API Error: unavailable',
    };
    expect(parseEvent(serializeEvent(failed))).toEqual(failed);

    const stopped: WorkerEvent = {
      event: 'stop',
      ts: 'T',
      prompt_id: 'prompt-1',
      transcript_path: '/tmp/transcript.jsonl',
      stop_hook_active: false,
      last_assistant_message: 'done',
      background_tasks: [{ id: 'task-1', type: 'shell', status: 'running' }],
      session_crons: [
        {
          id: 'cron-1',
          schedule: '0 9 * * 1-5',
          recurring: true,
          prompt: 'check build',
        },
      ],
    };
    expect(parseEvent(serializeEvent(stopped))).toEqual(stopped);
  });
  it('returns null for malformed json or unknown event', () => {
    expect(parseEvent('not json')).toBeNull();
    expect(parseEvent('{"event":"nope","ts":"T"}')).toBeNull();
  });
});
