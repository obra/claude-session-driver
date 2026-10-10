/**
 * Normalized turn model + shared markdown renderer + Claude transcript parser.
 *
 * PARSE is harness-specific: read a transcript's JSONL and produce a
 * NormalizedTurn. RENDER is shared: NormalizedTurn -> markdown. `parseClaudeTurn`
 * and `parseCodexTurn` both produce the SAME NormalizedTurn and reuse
 * `renderTurn`; the Pi driver will add its own parse the same way.
 *
 * This is a character-for-character port of the jq pipeline in the bash `csd`
 * (skills/driving-claude-code-sessions/scripts/csd). jq `-r` prints each emitted
 * string followed by a newline, so each rendered chunk (already ending in `\n`)
 * is followed by one more `\n` — see `renderTurn`.
 */

import { canonicalToolName } from './tool-name.js';

export type TurnItem =
  | { kind: 'prompt'; text: string }
  | { kind: 'thinking'; text: string }
  | { kind: 'text'; text: string }
  | { kind: 'tool_use'; name: string; input: unknown }
  | { kind: 'tool_result'; content: string; isError: boolean };

export type NormalizedTurn = TurnItem[];

const COMMAND_PREFIX = /^<(local-command|command-name)/;
const NO_OUTPUT = '(no output)';

interface ContentBlock {
  type?: unknown;
  text?: unknown;
  thinking?: unknown;
  name?: unknown;
  input?: unknown;
  content?: unknown;
  is_error?: unknown;
}

interface TranscriptLine {
  type?: unknown;
  message?: { content?: unknown; stop_reason?: unknown };
}

function parseLines(jsonl: string): TranscriptLine[] {
  const out: TranscriptLine[] = [];
  for (const line of jsonl.split('\n')) {
    if (line.length === 0) continue;
    try {
      out.push(JSON.parse(line) as TranscriptLine);
    } catch {
      // Real transcripts can contain partial/garbage lines; skip them.
    }
  }
  return out;
}

/** True for a `"type":"user"` line whose content is a real prompt string. */
function isPromptBoundary(line: TranscriptLine): boolean {
  if (line.type !== 'user') return false;
  const content = line.message?.content;
  return typeof content === 'string' && !COMMAND_PREFIX.test(content);
}

function findBoundary(lines: TranscriptLine[]): number {
  for (let i = lines.length - 1; i >= 0; i--) {
    if (isPromptBoundary(lines[i] as TranscriptLine)) return i;
  }
  return -1;
}

/**
 * Mirror jq's `.content // "(no output)"`: yield `(no output)` when content is
 * null/undefined; otherwise coerce to string. (An empty string passes through in
 * jq's `//`; we treat only null/undefined as missing for parity simplicity.)
 */
function resultContent(content: unknown): string {
  if (content === null || content === undefined) return NO_OUTPUT;
  return String(content);
}

/**
 * Narrow a raw array element to a block object, or null if it isn't one.
 * Real transcripts can contain partial/garbage array elements (null, numbers,
 * strings); mirror `parseLines`' graceful-degradation by skipping them rather
 * than throwing on `block.type`.
 */
function asBlock(x: unknown): ContentBlock | null {
  return typeof x === 'object' && x !== null ? (x as ContentBlock) : null;
}

function collectUser(line: TranscriptLine, out: NormalizedTurn): void {
  const content = line.message?.content;
  if (typeof content === 'string') {
    if (!COMMAND_PREFIX.test(content))
      out.push({ kind: 'prompt', text: content });
    return;
  }
  if (!Array.isArray(content)) return;
  for (const raw of content as unknown[]) {
    const block = asBlock(raw);
    if (!block) continue;
    if (block.type !== 'tool_result') continue;
    out.push({
      kind: 'tool_result',
      content: resultContent(block.content),
      isError: Boolean(block.is_error),
    });
  }
}

function collectAssistant(line: TranscriptLine, out: NormalizedTurn): void {
  const content = line.message?.content;
  if (!Array.isArray(content)) return;
  // A missing `thinking`/`text`/`name` field renders as an empty string rather
  // than the literal "undefined": graceful empty is clearer than jq's behavior
  // of dropping the whole turn when such a field is absent.
  for (const raw of content as unknown[]) {
    const block = asBlock(raw);
    if (!block) continue;
    if (block.type === 'thinking') {
      const text = typeof block.thinking === 'string' ? block.thinking : '';
      out.push({ kind: 'thinking', text });
    } else if (block.type === 'text') {
      const text = typeof block.text === 'string' ? block.text : '';
      out.push({ kind: 'text', text });
    } else if (block.type === 'tool_use') {
      const name = typeof block.name === 'string' ? block.name : '';
      out.push({
        kind: 'tool_use',
        name,
        input: block.input,
      });
    }
  }
}

/**
 * False while the latest turn's last assistant message stopped for a tool call:
 * Claude can fire its Stop hook before it writes the turn's closing message, so
 * a transcript read at that moment ends mid-turn. A missing stop_reason counts
 * as finished, so transcripts without the field behave as before.
 */
export function claudeTurnFinished(jsonl: string): boolean {
  const lines = parseLines(jsonl);
  const boundary = findBoundary(lines);
  if (boundary < 0) return true;
  const last = lines
    .slice(boundary)
    .filter((line) => line.type === 'assistant')
    .at(-1);
  return last?.message?.stop_reason !== 'tool_use';
}

export function parseClaudeTurn(jsonl: string): NormalizedTurn {
  const lines = parseLines(jsonl);
  const boundary = findBoundary(lines);
  if (boundary < 0) return [];

  const turn: NormalizedTurn = [];
  for (const line of lines.slice(boundary)) {
    if (line.type === 'user') collectUser(line, turn);
    else if (line.type === 'assistant') collectAssistant(line, turn);
  }
  return turn;
}

/**
 * Codex rollout parse. The rollout is JSONL of `{"type":"response_item",...}`
 * and `{"type":"event_msg",...}` lines. Parity with the bash `harness_parse_turn`
 * jq pipeline (drivers/codex.sh), normalized into the SHARED TurnItem model so
 * `renderTurn` works unchanged.
 *
 * Turn start = the last `response_item` with `payload.role == "user"`; if none,
 * start from line 1. From there each `response_item` maps:
 *   message(role=user)      -> prompt   (bash rendered `**[user]**`; we map to
 *   message(role!=user)     -> text      the existing kinds so the shared
 *   reasoning               -> thinking  renderer applies — see driver docs)
 *   function_call           -> tool_use   (arguments passed through: string or object)
 *   function_call_output    -> tool_result (output coerced to string, isError:false)
 * Anything else (and `event_msg`) is skipped. Parsing is defensive: malformed
 * lines, non-object payloads, and missing fields degrade to empty/skip, never throw.
 */

interface RolloutLine {
  type?: unknown;
  payload?: unknown;
}

interface RolloutPayload {
  type?: unknown;
  role?: unknown;
  content?: unknown;
  summary?: unknown;
  name?: unknown;
  arguments?: unknown;
  input?: unknown;
  output?: unknown;
}

function parseRolloutLines(jsonl: string): RolloutLine[] {
  const out: RolloutLine[] = [];
  for (const line of jsonl.split('\n')) {
    if (line.length === 0) continue;
    try {
      const parsed: unknown = JSON.parse(line);
      // Codex rollout JSONL can contain bare scalars; the object guard prevents
      // treating them as line objects (unlike Claude transcripts which are always objects).
      if (typeof parsed === 'object' && parsed !== null) {
        out.push(parsed as RolloutLine);
      }
    } catch {
      // Real rollouts can contain partial/garbage lines; skip them.
    }
  }
  return out;
}

function asPayload(line: RolloutLine): RolloutPayload | null {
  if (line.type !== 'response_item') return null;
  const p = line.payload;
  return typeof p === 'object' && p !== null ? (p as RolloutPayload) : null;
}

/** Join `content[].text` / `content[].output_text` of a codex message payload. */
function messageText(content: unknown): string {
  if (!Array.isArray(content)) return '';
  return (content as unknown[])
    .map((raw) => {
      const block = asBlock(raw);
      if (!block) return '';
      if (typeof block.text === 'string') return block.text;
      const out = (block as { output_text?: unknown }).output_text;
      return typeof out === 'string' ? out : '';
    })
    .join('');
}

/** Join the `text` of each reasoning `summary[]` entry (or the entry itself). */
function reasoningText(summary: unknown): string {
  if (!Array.isArray(summary)) return '';
  return (summary as unknown[])
    .map((raw) => {
      if (typeof raw === 'string') return raw;
      const block = asBlock(raw);
      return block && typeof block.text === 'string' ? block.text : '';
    })
    .join(' ');
}

/** Index of the last user `response_item` message, or 0 to start from line 1. */
function findCodexBoundary(lines: RolloutLine[]): number {
  for (let i = lines.length - 1; i >= 0; i--) {
    const p = asPayload(lines[i] as RolloutLine);
    if (p && p.type === 'message' && p.role === 'user') return i;
  }
  return 0;
}

/**
 * Codex names its shell tool `exec_command` in the rollout, but its hook payload
 * (and thus the csd event stream) reports the canonical `Bash`. Map rollout names
 * onto the same vocabulary so `read-turn` and `read-events` agree for the same
 * call; pass anything unmapped through (the native name beats a wrong guess).
 */
const CODEX_TOOL_NAMES: Record<string, string> = {
  exec_command: 'Bash',
};

function canonicalCodexTool(name: string): string {
  return CODEX_TOOL_NAMES[name] ?? name;
}

/**
 * Codex wraps each exec result in a metadata header — `Chunk ID`, `Wall time`,
 * `Process exited with code N`, `Original token count` — then a literal `Output:`
 * line and the real output. The default read-turn truncation would otherwise
 * show only that header, so collapse it to a single `exited <code> · <wall>s`
 * status line and keep the output. Anchored on the `Output:` boundary AND a
 * recognizable `Process exited with code` header; if either is absent (not an
 * exec result, or codex changed the format) the text passes through unchanged —
 * never drop data. Wall time is optional: omitted from the status if not found.
 */
function collapseCodexResult(text: string): string {
  const marker = '\nOutput:\n';
  const idx = text.indexOf(marker);
  if (idx === -1) return text;
  const header = text.slice(0, idx);
  // function_call_output headers say "Process exited with code N"; custom tools
  // (apply_patch) say "Exit code: N". Accept either.
  const exit = header.match(/(?:Process exited with code|Exit code:) (\S+)/);
  if (!exit) return text;
  const wall = header.match(/Wall time:\s*(\S+)\s*seconds/);
  const status = wall ? `exited ${exit[1]} · ${wall[1]}s` : `exited ${exit[1]}`;
  return `${status}\n${text.slice(idx + marker.length)}`;
}

export function parseCodexTurn(jsonl: string): NormalizedTurn {
  const lines = parseRolloutLines(jsonl);
  if (lines.length === 0) return [];
  const boundary = findCodexBoundary(lines);

  const turn: NormalizedTurn = [];
  for (const line of lines.slice(boundary)) {
    const p = asPayload(line);
    if (!p) continue;
    if (p.type === 'message') {
      const text = messageText(p.content);
      if (p.role === 'user') turn.push({ kind: 'prompt', text });
      else turn.push({ kind: 'text', text });
    } else if (p.type === 'reasoning') {
      turn.push({ kind: 'thinking', text: reasoningText(p.summary) });
    } else if (p.type === 'function_call' || p.type === 'custom_tool_call') {
      // Codex shell tools arrive as function_call (args in `arguments`); native
      // tools like apply_patch arrive as custom_tool_call (args in `input`).
      // Both render as a tool_use — otherwise apply_patch edits vanish from
      // read-turn (BUG-1).
      const name = canonicalCodexTool(typeof p.name === 'string' ? p.name : '');
      const input = p.type === 'custom_tool_call' ? p.input : p.arguments;
      turn.push({ kind: 'tool_use', name, input });
    } else if (
      p.type === 'function_call_output' ||
      p.type === 'custom_tool_call_output'
    ) {
      turn.push({
        kind: 'tool_result',
        content: collapseCodexResult(resultContent(p.output)),
        isError: false,
      });
    }
  }
  return turn;
}

/**
 * Pi session-transcript parse. The pi session file is JSONL whose line 1 is a
 * `{"type":"session",...}` HEADER and whose subsequent `{"type":"message",...}`
 * entries wrap an `AgentMessage` under `entry.message`. Other entry types
 * (model_change, thinking_level_change, compaction, …) are skipped. Normalized
 * into the SHARED TurnItem model so `renderTurn` works unchanged (mirrors
 * parseClaudeTurn/parseCodexTurn).
 *
 * Turn start = the last message entry whose `message.role === "user"`; if none,
 * start from the first message entry. From there each message entry maps:
 *   role "user"       -> prompt   (content: string OR (text|image)[] joined)
 *   role "assistant"  -> per content block:
 *                          text     -> text
 *                          thinking -> thinking   (text from `.thinking`)
 *                          toolCall -> tool_use    ({type:"toolCall",name,arguments};
 *                                                   NOTE: "toolCall", not "toolUse")
 *   role "toolResult" -> tool_result (content (text|image)[] joined; isError flag)
 * Parsing is defensive: malformed lines, non-object entries, the header line,
 * unknown entry types, and missing fields degrade to empty/skip, never throw.
 */

interface PiEntry {
  type?: unknown;
  message?: unknown;
}

interface PiMessage {
  role?: unknown;
  content?: unknown;
  thinking?: unknown;
  name?: unknown;
  arguments?: unknown;
  isError?: unknown;
}

function parsePiEntries(jsonl: string): PiEntry[] {
  const out: PiEntry[] = [];
  for (const line of jsonl.split('\n')) {
    if (line.length === 0) continue;
    try {
      const parsed: unknown = JSON.parse(line);
      // Pi session JSONL is always objects, but guard against bare scalars.
      if (typeof parsed === 'object' && parsed !== null) {
        out.push(parsed as PiEntry);
      }
    } catch {
      // Real session files can contain partial/garbage lines; skip them.
    }
  }
  return out;
}

/** The inner AgentMessage of a `type:"message"` entry, or null otherwise. */
function asPiMessage(entry: PiEntry): PiMessage | null {
  if (entry.type !== 'message') return null;
  const m = entry.message;
  return typeof m === 'object' && m !== null ? (m as PiMessage) : null;
}

/**
 * Join a pi message `content` into a single string: a bare string passes
 * through; an array joins its `{type:"text",text}` blocks (image/other blocks
 * contribute nothing).
 */
function piContentText(content: unknown): string {
  if (typeof content === 'string') return content;
  if (!Array.isArray(content)) return '';
  return (content as unknown[])
    .map((raw) => {
      const block = asBlock(raw);
      if (block?.type !== 'text') return '';
      return typeof block.text === 'string' ? block.text : '';
    })
    .join('');
}

/** Index of the last user `message` entry, or 0 to start from the first one. */
function findPiBoundary(entries: PiEntry[]): number {
  for (let i = entries.length - 1; i >= 0; i--) {
    const m = asPiMessage(entries[i] as PiEntry);
    if (m && m.role === 'user') return i;
  }
  return 0;
}

function collectPiAssistant(content: unknown, out: NormalizedTurn): void {
  if (!Array.isArray(content)) return;
  for (const raw of content as unknown[]) {
    const block = asBlock(raw);
    if (!block) continue;
    if (block.type === 'thinking') {
      const text = typeof block.thinking === 'string' ? block.thinking : '';
      out.push({ kind: 'thinking', text });
    } else if (block.type === 'text') {
      const text = typeof block.text === 'string' ? block.text : '';
      out.push({ kind: 'text', text });
    } else if (block.type === 'toolCall') {
      const piBlock = block as PiMessage;
      out.push({
        kind: 'tool_use',
        name: canonicalToolName(piBlock.name),
        input: piBlock.arguments,
      });
    }
  }
}

export function parsePiTurn(jsonl: string): NormalizedTurn {
  const entries = parsePiEntries(jsonl);
  if (entries.length === 0) return [];
  const boundary = findPiBoundary(entries);

  const turn: NormalizedTurn = [];
  for (const entry of entries.slice(boundary)) {
    const m = asPiMessage(entry);
    if (!m) continue;
    if (m.role === 'user') {
      turn.push({ kind: 'prompt', text: piContentText(m.content) });
    } else if (m.role === 'assistant') {
      collectPiAssistant(m.content, turn);
    } else if (m.role === 'toolResult') {
      // Pi always sends toolResult content as an array of typed blocks (never a
      // bare null string), so piContentText (returns '' for null/non-array) is
      // correct here. Claude/codex use resultContent which returns '(no output)'
      // for null — that bare-string-null case does not arise in pi's format.
      turn.push({
        kind: 'tool_result',
        content: piContentText(m.content),
        isError: Boolean(m.isError),
      });
    }
  }
  return turn;
}

/** Compact JSON for an object; the raw string for a string (jq `tostring`). */
function compactJson(input: unknown): string {
  if (typeof input === 'string') return input;
  return JSON.stringify(input);
}

function truncate(content: string): string {
  const ls = content.split('\n');
  if (ls.length > 5) {
    return `${ls.slice(0, 5).join('\n')}\n... (${ls.length} lines total)`;
  }
  return ls.join('\n');
}

function renderItem(item: TurnItem, full: boolean): string {
  switch (item.kind) {
    case 'prompt':
      return `---\n\n**Prompt:** ${item.text}\n`;
    case 'thinking':
      // A turn with no thinking content yields an empty item; render nothing
      // rather than a bare `> **Thinking:** ` line (RE-1).
      if (item.text.trim() === '') return '';
      return `> **Thinking:** ${item.text.split('\n').join('\n> ')}\n`;
    case 'text':
      return `${item.text}\n`;
    case 'tool_use':
      return `**Tool: ${item.name}**\n\`\`\`json\n${compactJson(item.input)}\n\`\`\`\n`;
    case 'tool_result': {
      if (item.isError) {
        return `**Tool Error:**\n\`\`\`\n${item.content}\n\`\`\`\n`;
      }
      const body = full ? item.content : truncate(item.content);
      return `**Result:**\n\`\`\`\n${body}\n\`\`\`\n`;
    }
  }
}

export function renderTurn(
  turn: NormalizedTurn,
  opts: { full: boolean },
): string {
  // jq `-r` prints each emitted string followed by a newline; each chunk already
  // ends in `\n`, so the per-output separator adds one more `\n` per chunk.
  return turn.map((item) => `${renderItem(item, opts.full)}\n`).join('');
}

/**
 * The markdown turn as a `read-turn`/`converse --with-turn` command result.
 *
 * `renderTurn` ends in `\n\n` (the jq `-r` parity ending). The CLI's `emit`
 * appends one more `\n` to every command's stdout, which would make the worker
 * surface emit THREE trailing newlines where bash's `read-turn` emits exactly
 * two. Strip a single trailing `\n` here so emit's append lands back on bash's
 * `\n\n`. Both command paths (read-turn and converse --with-turn) use this, so
 * they stay byte-identical.
 */
export function renderTurnForCommand(
  turn: NormalizedTurn,
  opts: { full: boolean },
): string {
  return renderTurn(turn, opts).replace(/\n$/, '');
}

/**
 * The assistant's reply text for a parsed turn: the `text` items joined with
 * newlines. Harness-agnostic — works for any driver's `parseTurn` output, so
 * converse can extract the reply uniformly across claude/codex/pi (the
 * claude-only `lastAssistantText` count-gate could not). Empty when the turn has
 * no assistant text yet (e.g. the transcript has not caught up after `stop`).
 */
export function assistantText(turn: NormalizedTurn): string {
  return turn
    .filter(
      (item): item is Extract<TurnItem, { kind: 'text' }> =>
        item.kind === 'text',
    )
    .map((item) => item.text)
    .join('\n');
}
