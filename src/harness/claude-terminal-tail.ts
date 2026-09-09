import { createHash } from 'node:crypto';
import { closeSync, fstatSync, openSync, readSync, type Stats } from 'node:fs';
import { TextDecoder } from 'node:util';

export const MAX_TRANSCRIPT_CAPTURE_BYTES = 1024 * 1024;
export const MAX_TRANSCRIPT_TAIL_BYTES = 1024 * 1024;

export interface ClaudeTranscriptAnchor {
  uuid: string;
  lineStart: number;
  lineEnd: number;
  afterOffset: number;
  capturedSize: number;
  device: number;
  inode: number;
  snapshotDigest: string;
  newlineTerminated: boolean;
}

export type ClaudeTerminalTailReason =
  | 'anchor_absent'
  | 'anchor_mismatch'
  | 'transcript_replaced'
  | 'transcript_rewritten'
  | 'tail_too_large'
  | 'malformed_tail'
  | 'sidechain_api_error'
  | 'api_error_not_descendant'
  | 'unknown_chain_record'
  | 'later_substantive_assistant'
  | 'later_conversation_record'
  | 'missing_terminal_api_error'
  | 'transcript_unreadable';

export type ClaudeTerminalTailResult =
  | {
      kind: 'api_error';
      evidenceSource: 'claude_transcript_tail';
      transcriptPath: string;
      terminalRecordUuid: string;
      lastAssistantMessage?: string;
    }
  | {
      kind: 'indeterminate';
      reason: ClaudeTerminalTailReason;
      transcriptPath: string;
    };

const decoder = new TextDecoder('utf-8', { fatal: true });
const CLAUDE_CHAIN_TYPES = new Set([
  'user',
  'assistant',
  'attachment',
  'system',
  'progress',
]);

function readExact(fd: number, start: number, length: number): Buffer | null {
  const buffer = Buffer.alloc(length);
  let offset = 0;
  try {
    while (offset < length) {
      const count = readSync(
        fd,
        buffer,
        offset,
        length - offset,
        start + offset,
      );
      if (count === 0) return null;
      offset += count;
    }
  } catch {
    return null;
  }
  return buffer;
}

function parseRecord(bytes: Uint8Array): Record<string, unknown> | null {
  try {
    const value: unknown = JSON.parse(decoder.decode(bytes));
    return typeof value === 'object' && value !== null
      ? (value as Record<string, unknown>)
      : null;
  } catch {
    return null;
  }
}

function digest(bytes: Uint8Array): string {
  return createHash('sha256').update(bytes).digest('hex');
}

function openTranscript(file: string): { fd: number; stat: Stats } | null {
  try {
    const fd = openSync(file, 'r');
    try {
      const stat = fstatSync(fd);
      if (!stat.isFile()) {
        closeSync(fd);
        return null;
      }
      return { fd, stat };
    } catch {
      closeSync(fd);
      return null;
    }
  } catch {
    return null;
  }
}

/**
 * Capture the last complete UUID-bearing record from a fixed-size tail window.
 * Invalid JSON/UTF-8 or a record wider than the window disables the fallback.
 */
export function captureClaudeTranscriptAnchor(
  file: string,
): ClaudeTranscriptAnchor | null {
  const opened = openTranscript(file);
  if (opened === null) return null;
  const { fd, stat } = opened;
  try {
    if (stat.size === 0) return null;
    const windowStart = Math.max(0, stat.size - MAX_TRANSCRIPT_CAPTURE_BYTES);
    const window = readExact(fd, windowStart, stat.size - windowStart);
    if (window === null) return null;

    let cursor = 0;
    if (windowStart > 0) {
      const firstNewline = window.indexOf(0x0a);
      if (firstNewline < 0) return null;
      cursor = firstNewline + 1;
    }

    let last:
      | {
          uuid: string;
          lineStart: number;
          lineEnd: number;
          afterOffset: number;
          newlineTerminated: boolean;
        }
      | undefined;
    while (cursor < window.length) {
      const newline = window.indexOf(0x0a, cursor);
      const lineEnd = newline < 0 ? window.length : newline;
      if (lineEnd > cursor) {
        const parsed = parseRecord(window.subarray(cursor, lineEnd));
        if (parsed === null) return null;
        if (typeof parsed.uuid === 'string') {
          if (
            parsed.isSidechain === true ||
            typeof parsed.type !== 'string' ||
            !CLAUDE_CHAIN_TYPES.has(parsed.type)
          ) {
            return null;
          }
          last = {
            uuid: parsed.uuid,
            lineStart: windowStart + cursor,
            lineEnd: windowStart + lineEnd,
            afterOffset: windowStart + lineEnd + (newline < 0 ? 0 : 1),
            newlineTerminated: newline >= 0,
          };
        }
      }
      if (newline < 0) break;
      cursor = newline + 1;
    }
    if (last === undefined) return null;

    const snapshotStart = last.lineStart - windowStart;
    return {
      ...last,
      capturedSize: stat.size,
      device: stat.dev,
      inode: stat.ino,
      snapshotDigest: digest(window.subarray(snapshotStart)),
    };
  } finally {
    closeSync(fd);
  }
}

function parseJsonl(bytes: Buffer): Record<string, unknown>[] | null {
  const records: Record<string, unknown>[] = [];
  let cursor = 0;
  while (cursor < bytes.length) {
    const newline = bytes.indexOf(0x0a, cursor);
    const lineEnd = newline < 0 ? bytes.length : newline;
    if (lineEnd > cursor) {
      const parsed = parseRecord(bytes.subarray(cursor, lineEnd));
      if (parsed === null) return null;
      records.push(parsed);
    }
    if (newline < 0) break;
    cursor = newline + 1;
  }
  return records;
}

function assistantContent(value: unknown): Array<Record<string, unknown>> {
  if (!Array.isArray(value)) return [];
  return value.filter(
    (item): item is Record<string, unknown> =>
      typeof item === 'object' && item !== null,
  );
}

function message(record: Record<string, unknown>): Record<string, unknown> {
  const value = record.message;
  return typeof value === 'object' && value !== null
    ? (value as Record<string, unknown>)
    : {};
}

function substantiveAssistant(record: Record<string, unknown>): boolean {
  if (record.type !== 'assistant') return false;
  const content = message(record).content;
  if (typeof content === 'string') return content.length > 0;
  return assistantContent(content).some(
    (block) =>
      block.type === 'tool_use' ||
      (block.type === 'text' &&
        typeof block.text === 'string' &&
        block.text.length > 0),
  );
}

function assistantText(record: Record<string, unknown>): string | undefined {
  const content = message(record).content;
  if (typeof content === 'string')
    return content.length > 0 ? content : undefined;
  const text = assistantContent(content)
    .filter((block) => block.type === 'text' && typeof block.text === 'string')
    .map((block) => block.text as string)
    .join('');
  return text.length > 0 ? text : undefined;
}

function descendsFromAnchor(
  candidate: Record<string, unknown>,
  anchor: ClaudeTranscriptAnchor,
  byUuid: Map<string, Record<string, unknown>>,
): ClaudeTerminalTailReason | null {
  const seen = new Set<string>();
  let parent = candidate.parentUuid;
  while (typeof parent === 'string') {
    if (parent === anchor.uuid) return null;
    if (seen.has(parent)) return 'api_error_not_descendant';
    seen.add(parent);
    const record = byUuid.get(parent);
    if (record === undefined) return 'api_error_not_descendant';
    if (record.isSidechain === true) return 'sidechain_api_error';
    if (
      typeof record.type !== 'string' ||
      !CLAUDE_CHAIN_TYPES.has(record.type)
    ) {
      return 'unknown_chain_record';
    }
    parent = record.parentUuid;
  }
  return 'api_error_not_descendant';
}

function indeterminate(
  file: string,
  reason: ClaudeTerminalTailReason,
): ClaudeTerminalTailResult {
  return { kind: 'indeterminate', reason, transcriptPath: file };
}

/**
 * Revalidate a pre-send anchor, then inspect at most one fixed-size JSONL tail.
 * This proves only a main-chain API error descended from that anchor; it never
 * reconstructs the full transcript or infers normal completion.
 */
export function inspectClaudeTerminalTail(
  file: string,
  anchor: ClaudeTranscriptAnchor | null,
): ClaudeTerminalTailResult {
  if (anchor === null) return indeterminate(file, 'anchor_absent');
  const opened = openTranscript(file);
  if (opened === null) return indeterminate(file, 'transcript_unreadable');
  const { fd, stat } = opened;

  try {
    if (stat.dev !== anchor.device || stat.ino !== anchor.inode) {
      return indeterminate(file, 'transcript_replaced');
    }
    if (stat.size < anchor.capturedSize || stat.size < anchor.afterOffset) {
      return indeterminate(file, 'transcript_rewritten');
    }
    if (!anchor.newlineTerminated && stat.size > anchor.capturedSize) {
      return indeterminate(file, 'anchor_mismatch');
    }

    const snapshotLength = anchor.capturedSize - anchor.lineStart;
    if (snapshotLength > MAX_TRANSCRIPT_CAPTURE_BYTES) {
      return indeterminate(file, 'anchor_mismatch');
    }
    const snapshot = readExact(fd, anchor.lineStart, snapshotLength);
    if (snapshot === null) {
      return indeterminate(file, 'transcript_unreadable');
    }
    if (digest(snapshot) !== anchor.snapshotDigest) {
      return indeterminate(file, 'transcript_rewritten');
    }
    const anchorLength = anchor.lineEnd - anchor.lineStart;
    const anchorRecord = parseRecord(snapshot.subarray(0, anchorLength));
    if (anchorRecord?.uuid !== anchor.uuid) {
      return indeterminate(file, 'anchor_mismatch');
    }

    const tailLength = stat.size - anchor.afterOffset;
    if (tailLength > MAX_TRANSCRIPT_TAIL_BYTES) {
      return indeterminate(file, 'tail_too_large');
    }
    const tailBytes = readExact(fd, anchor.afterOffset, tailLength);
    if (tailBytes === null) return indeterminate(file, 'transcript_unreadable');
    const tail = parseJsonl(tailBytes);
    if (tail === null) return indeterminate(file, 'malformed_tail');

    const byUuid = new Map<string, Record<string, unknown>>();
    for (const record of tail) {
      if (typeof record.uuid !== 'string') continue;
      if (
        typeof record.type !== 'string' ||
        !CLAUDE_CHAIN_TYPES.has(record.type)
      ) {
        return indeterminate(file, 'unknown_chain_record');
      }
      if (byUuid.has(record.uuid)) return indeterminate(file, 'malformed_tail');
      byUuid.set(record.uuid, record);
    }

    let terminalIndex = -1;
    for (let index = tail.length - 1; index >= 0; index--) {
      const candidate = tail[index];
      if (
        candidate?.type === 'assistant' &&
        candidate.isApiErrorMessage === true &&
        typeof candidate.uuid === 'string'
      ) {
        terminalIndex = index;
        break;
      }
    }
    if (terminalIndex < 0) {
      return indeterminate(file, 'missing_terminal_api_error');
    }

    const terminal = tail[terminalIndex] as Record<string, unknown>;
    if (terminal.isSidechain === true) {
      return indeterminate(file, 'sidechain_api_error');
    }
    const ancestryFailure = descendsFromAnchor(terminal, anchor, byUuid);
    if (ancestryFailure !== null) return indeterminate(file, ancestryFailure);

    for (const later of tail.slice(terminalIndex + 1)) {
      if (substantiveAssistant(later)) {
        return indeterminate(file, 'later_substantive_assistant');
      }
      if (later.type === 'user') {
        return indeterminate(file, 'later_conversation_record');
      }
    }

    const text = assistantText(terminal);
    return {
      kind: 'api_error',
      evidenceSource: 'claude_transcript_tail',
      transcriptPath: file,
      terminalRecordUuid: terminal.uuid as string,
      ...(text === undefined ? {} : { lastAssistantMessage: text }),
    };
  } finally {
    closeSync(fd);
  }
}
