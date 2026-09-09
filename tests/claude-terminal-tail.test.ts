import {
  appendFileSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { afterEach, describe, expect, it } from 'vitest';
import {
  type ClaudeTranscriptAnchor,
  captureClaudeTranscriptAnchor,
  inspectClaudeTerminalTail,
  MAX_TRANSCRIPT_CAPTURE_BYTES,
  MAX_TRANSCRIPT_TAIL_BYTES,
} from '../src/harness/claude-terminal-tail.js';

const created: string[] = [];

function scratch(content: string | Buffer): string {
  const dir = mkdtempSync(join(tmpdir(), 'csd-claude-tail-'));
  created.push(dir);
  const file = join(dir, 'session.jsonl');
  writeFileSync(file, content);
  return file;
}

function capture(file: string): ClaudeTranscriptAnchor {
  const anchor = captureClaudeTranscriptAnchor(file);
  if (anchor === null) throw new Error('expected a transcript anchor');
  return anchor;
}

function appendRecords(file: string, records: string[]): void {
  appendFileSync(file, `${records.join('\n')}\n`);
}

afterEach(() => {
  for (const dir of created.splice(0)) rmSync(dir, { recursive: true });
});

describe('captureClaudeTranscriptAnchor', () => {
  it('captures validated byte offsets for the last UUID record, not a sidecar', () => {
    const content = [
      '{"type":"assistant","uuid":"anchor-a"}',
      '{"type":"last-prompt","leafUuid":"anchor-a"}',
      '{"type":"assistant","uuid":"anchor-b"}',
      '{"type":"mode","mode":"default"}',
      '',
    ].join('\n');
    const file = scratch(content);
    const anchor = capture(file);
    expect(anchor).toMatchObject({
      uuid: 'anchor-b',
      capturedSize: Buffer.byteLength(content),
      newlineTerminated: true,
    });
    expect(anchor.lineStart).toBeGreaterThan(0);
    expect(anchor.lineEnd).toBeGreaterThan(anchor.lineStart);
    expect(anchor.afterOffset).toBe(anchor.lineEnd + 1);
    expect(anchor.snapshotDigest).toMatch(/^[0-9a-f]{64}$/);
  });

  it('returns null without a complete UUID-bearing record', () => {
    const file = scratch('{"type":"last-prompt"}\n{"uuid":');
    expect(captureClaudeTranscriptAnchor(file)).toBeNull();
  });

  it('returns null for a non-regular transcript path', () => {
    const file = scratch('{"type":"user","uuid":"anchor"}\n');
    expect(captureClaudeTranscriptAnchor(dirname(file))).toBeNull();
  });

  it('returns null when the capture window contains an unknown UUID type', () => {
    const file = scratch(
      [
        '{"type":"user","uuid":"anchor"}',
        '{"type":"future-chain-node","uuid":"future","parentUuid":"anchor"}',
        '',
      ].join('\n'),
    );
    expect(captureClaudeTranscriptAnchor(file)).toBeNull();
  });

  it('returns null when one record is wider than the capture window', () => {
    const file = scratch(
      JSON.stringify({
        uuid: 'too-wide',
        text: 'x'.repeat(MAX_TRANSCRIPT_CAPTURE_BYTES),
      }),
    );
    expect(captureClaudeTranscriptAnchor(file)).toBeNull();
  });
});

describe('inspectClaudeTerminalTail', () => {
  it('recognizes a descendant empirical API-error tail after its anchor', () => {
    const fixture = join(
      dirname(fileURLToPath(import.meta.url)),
      'fixtures',
      'claude-transcripts',
      'response-stopped-arriving.jsonl',
    );
    const fixtureLines = readFileSync(fixture, 'utf8').trimEnd().split('\n');
    const file = scratch(`${fixtureLines[0]}\n`);
    const anchor = capture(file);
    appendRecords(file, fixtureLines.slice(1));

    expect(inspectClaudeTerminalTail(file, anchor)).toEqual({
      kind: 'api_error',
      evidenceSource: 'claude_transcript_tail',
      transcriptPath: file,
      terminalRecordUuid: '22222222-2222-4222-8222-222222222222',
      lastAssistantMessage: '<redacted API error>',
    });
  });

  it('does not inspect an API error that existed before capture', () => {
    const file = scratch(
      [
        '{"type":"assistant","uuid":"old-error","isApiErrorMessage":true,"isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"old"}]}}',
        '{"type":"user","uuid":"anchor","parentUuid":"old-error","message":{"role":"user","content":"new"}}',
        '',
      ].join('\n'),
    );
    const anchor = capture(file);
    appendRecords(file, [
      '{"type":"assistant","uuid":"normal","parentUuid":"anchor","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"new reply"}]}}',
    ]);
    expect(inspectClaudeTerminalTail(file, anchor)).toMatchObject({
      kind: 'indeterminate',
      reason: 'missing_terminal_api_error',
    });
  });

  it('keeps timeout without a captured anchor', () => {
    const file = scratch(
      '{"type":"assistant","uuid":"error","isApiErrorMessage":true}\n',
    );
    expect(inspectClaudeTerminalTail(file, null)).toMatchObject({
      kind: 'indeterminate',
      reason: 'anchor_absent',
    });
  });

  it('fails closed when the transcript becomes unreadable after capture', () => {
    const file = scratch('{"type":"user","uuid":"anchor"}\n');
    const anchor = capture(file);
    rmSync(file);
    expect(inspectClaudeTerminalTail(file, anchor)).toMatchObject({
      kind: 'indeterminate',
      reason: 'transcript_unreadable',
    });
  });

  it('keeps timeout when the anchored snapshot is rewritten in place', () => {
    const file = scratch('{"type":"user","uuid":"anchor-original"}\n');
    const anchor = capture(file);
    writeFileSync(file, '{"type":"user","uuid":"anchor-rewritten"}\n');
    expect(inspectClaudeTerminalTail(file, anchor)).toMatchObject({
      kind: 'indeterminate',
      reason: 'transcript_rewritten',
    });
  });

  it('keeps timeout when the bounded tail is too large', () => {
    const file = scratch('{"type":"user","uuid":"anchor"}\n');
    const anchor = capture(file);
    appendFileSync(file, Buffer.alloc(MAX_TRANSCRIPT_TAIL_BYTES + 1, 0x20));
    expect(inspectClaudeTerminalTail(file, anchor)).toMatchObject({
      kind: 'indeterminate',
      reason: 'tail_too_large',
    });
  });

  it('keeps timeout when any record after the anchor is malformed', () => {
    const file = scratch('{"type":"user","uuid":"anchor"}\n');
    const anchor = capture(file);
    appendFileSync(file, '{"type":"assistant",');
    expect(inspectClaudeTerminalTail(file, anchor)).toMatchObject({
      kind: 'indeterminate',
      reason: 'malformed_tail',
    });
  });

  it('rejects a physically later API error on an unrelated branch', () => {
    const file = scratch('{"type":"user","uuid":"anchor"}\n');
    const anchor = capture(file);
    appendRecords(file, [
      '{"type":"user","uuid":"orphan","parentUuid":null}',
      '{"type":"assistant","uuid":"orphan-error","parentUuid":"orphan","isSidechain":false,"isApiErrorMessage":true,"message":{"role":"assistant","content":[{"type":"text","text":"orphan error"}]}}',
    ]);
    expect(inspectClaudeTerminalTail(file, anchor)).toMatchObject({
      kind: 'indeterminate',
      reason: 'api_error_not_descendant',
    });
  });

  it('rejects a sidechain API error even when it points at the anchor', () => {
    const file = scratch('{"type":"user","uuid":"anchor"}\n');
    const anchor = capture(file);
    appendRecords(file, [
      '{"type":"assistant","uuid":"side-error","parentUuid":"anchor","isSidechain":true,"isApiErrorMessage":true,"message":{"role":"assistant","content":[{"type":"text","text":"side error"}]}}',
    ]);
    expect(inspectClaudeTerminalTail(file, anchor)).toMatchObject({
      kind: 'indeterminate',
      reason: 'sidechain_api_error',
    });
  });

  it('rejects an unknown UUID-bearing ancestry node', () => {
    const file = scratch('{"type":"user","uuid":"anchor"}\n');
    const anchor = capture(file);
    appendRecords(file, [
      '{"type":"future-chain-node","uuid":"future","parentUuid":"anchor","isSidechain":false}',
      '{"type":"assistant","uuid":"error","parentUuid":"future","isSidechain":false,"isApiErrorMessage":true,"message":{"role":"assistant","content":[{"type":"text","text":"must remain indeterminate"}]}}',
    ]);
    expect(inspectClaudeTerminalTail(file, anchor)).toMatchObject({
      kind: 'indeterminate',
      reason: 'unknown_chain_record',
    });
  });

  it('rejects an unknown UUID-bearing record after a valid API error', () => {
    const file = scratch('{"type":"user","uuid":"anchor"}\n');
    const anchor = capture(file);
    appendRecords(file, [
      '{"type":"assistant","uuid":"error","parentUuid":"anchor","isSidechain":false,"isApiErrorMessage":true,"message":{"role":"assistant","content":[{"type":"text","text":"error"}]}}',
      '{"type":"future-chain-node","uuid":"future","parentUuid":"error","isSidechain":false}',
    ]);
    expect(inspectClaudeTerminalTail(file, anchor)).toMatchObject({
      kind: 'indeterminate',
      reason: 'unknown_chain_record',
    });
  });

  it.each([
    ['text', '{"type":"text","text":"recovered"}'],
    ['tool use', '{"type":"tool_use","name":"Bash","input":{}}'],
  ])('keeps timeout when substantive %s follows the API error', (_label, block) => {
    const file = scratch('{"type":"user","uuid":"anchor"}\n');
    const anchor = capture(file);
    appendRecords(file, [
      '{"type":"assistant","uuid":"error","parentUuid":"anchor","isSidechain":false,"isApiErrorMessage":true,"message":{"role":"assistant","content":[{"type":"text","text":"error"}]}}',
      `{"type":"assistant","uuid":"later","parentUuid":"error","isSidechain":false,"message":{"role":"assistant","content":[${block}]}}`,
    ]);
    expect(inspectClaudeTerminalTail(file, anchor)).toMatchObject({
      kind: 'indeterminate',
      reason: 'later_substantive_assistant',
    });
  });

  it('keeps timeout when the tail has no marked terminal record', () => {
    const file = scratch('{"type":"user","uuid":"anchor"}\n');
    const anchor = capture(file);
    appendRecords(file, [
      '{"type":"assistant","uuid":"normal","parentUuid":"anchor","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"partial"}]}}',
    ]);
    expect(inspectClaudeTerminalTail(file, anchor)).toMatchObject({
      kind: 'indeterminate',
      reason: 'missing_terminal_api_error',
    });
  });
});
