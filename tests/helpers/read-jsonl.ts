import { readFileSync } from 'node:fs';

export interface MalformedJsonlLine {
  line: number;
  text: string;
}

export interface JsonlReadResult {
  records: unknown[];
  malformed: MalformedJsonlLine[];
}

/** Read every non-empty JSONL line without silently discarding torn records. */
export function readJsonl(file: string): JsonlReadResult {
  const records: unknown[] = [];
  const malformed: MalformedJsonlLine[] = [];

  for (const [index, line] of readFileSync(file, 'utf8')
    .split('\n')
    .entries()) {
    if (line.length === 0) continue;
    try {
      records.push(JSON.parse(line));
    } catch {
      malformed.push({ line: index + 1, text: line });
    }
  }

  return { records, malformed };
}
