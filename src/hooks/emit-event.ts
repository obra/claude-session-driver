import { existsSync } from 'node:fs';
import { appendEvent } from '../core/event-log.js';
import { eventsPath, metaPath, workerDir } from '../core/paths.js';
import { isoSecondsUtc } from '../core/time.js';
import { writeMeta } from '../core/worker-store.js';
import type {
  BackgroundTaskEvidence,
  EventName,
  SessionCronEvidence,
  WorkerEvent,
} from '../events.js';

/**
 * The session lifecycle hook for Claude Code (and Codex). Claude/Codex invoke
 * the bundled `dist/emit-event.cjs` on each lifecycle event, piping the hook
 * payload JSON on stdin. The hook appends a normalized WorkerEvent to the
 * worker's events JSONL file — but only for managed worker sessions (those
 * with a `<session_id>.meta` file under the worker dir).
 *
 * Ported from the original bash/jq hook (issue #15: bash and jq are not on
 * Claude Code's hook PATH on Windows). Behavior is observation-only: it records
 * what a worker is doing so a controller can watch the event stream.
 */

/** What the entry point should print to stdout, plus the event it appended. */
export interface HookResult {
  stdout: string;
  appended?: WorkerEvent;
}

interface HookOptions {
  /** Raw hook payload string read from stdin. */
  stdin: string;
  /** Worker dir where `<sid>.meta` and `<sid>.events.jsonl` live. */
  workerDir: string;
  /** Injectable clock: returns the ISO-8601 ts to stamp on the event. */
  now: () => string;
  /**
   * Codex's baked hook args (tmux_name, cwd). Present only on the derive path:
   * codex mints its own session id, so no `<sid>.meta` can exist at launch. When
   * given, the hook SELF-REGISTERS `<sid>.meta` (harness `codex`) on the first
   * event for that sid. Absent on the claude path, where the meta is written at
   * launch and a missing meta means "not a managed worker" (no-op).
   */
  baked?: { tmuxName: string; cwd: string };
}

/** Claude/Codex hook event names mapped to our snake_case WorkerEvent names. */
const EVENT_MAP: Record<string, EventName> = {
  SessionStart: 'session_start',
  Stop: 'stop',
  StopFailure: 'stop_failure',
  UserPromptSubmit: 'user_prompt_submit',
  SessionEnd: 'session_end',
  PreToolUse: 'pre_tool_use',
  PostToolUse: 'post_tool_use',
};

function asRecord(v: unknown): Record<string, unknown> | null {
  return typeof v === 'object' && v !== null
    ? (v as Record<string, unknown>)
    : null;
}

function asString(v: unknown): string {
  return typeof v === 'string' ? v : '';
}

export const MAX_EVENT_TEXT_LENGTH = 8192;

function boundedString(v: unknown): string | undefined {
  return typeof v === 'string' ? v.slice(0, MAX_EVENT_TEXT_LENGTH) : undefined;
}

function optionalString(v: unknown): string | undefined {
  return typeof v === 'string' && v.length > 0 ? v : undefined;
}

function terminalEvidence(payload: Record<string, unknown>): {
  prompt_id?: string;
  transcript_path?: string;
  last_assistant_message?: string;
} {
  const promptId = optionalString(payload.prompt_id);
  const transcriptPath = optionalString(payload.transcript_path);
  const lastAssistantMessage = boundedString(payload.last_assistant_message);
  return {
    ...(promptId === undefined ? {} : { prompt_id: promptId }),
    ...(transcriptPath === undefined
      ? {}
      : { transcript_path: transcriptPath }),
    ...(lastAssistantMessage === undefined
      ? {}
      : { last_assistant_message: lastAssistantMessage }),
  };
}

function backgroundTasks(v: unknown): BackgroundTaskEvidence[] | undefined {
  if (!Array.isArray(v)) return undefined;
  return v.flatMap((item) => {
    const record = asRecord(item);
    if (record === null) return [];
    const id = optionalString(record.id);
    const type = optionalString(record.type);
    const status = optionalString(record.status);
    return [
      {
        ...(id === undefined ? {} : { id }),
        ...(type === undefined ? {} : { type }),
        ...(status === undefined ? {} : { status }),
      },
    ];
  });
}

function sessionCrons(v: unknown): SessionCronEvidence[] | undefined {
  if (!Array.isArray(v)) return undefined;
  return v.flatMap((item) => {
    const record = asRecord(item);
    if (record === null) return [];
    const id = optionalString(record.id);
    const schedule = optionalString(record.schedule);
    const recurring =
      typeof record.recurring === 'boolean' ? record.recurring : undefined;
    const prompt = boundedString(record.prompt);
    return [
      {
        ...(id === undefined ? {} : { id }),
        ...(schedule === undefined ? {} : { schedule }),
        ...(recurring === undefined ? {} : { recurring }),
        ...(prompt === undefined ? {} : { prompt }),
      },
    ];
  });
}

/**
 * Pure hook logic: parse the payload, append a WorkerEvent if this is a managed
 * worker session with a recognized event, and report what to print on stdout.
 *
 * Never throws on malformed or unexpected input — empty/invalid JSON, missing
 * session_id, missing meta, or an unrecognized event name all return
 * `{ stdout: '' }` with nothing appended. A non-zero exit on the Stop hook can
 * break session shutdown (issue #15), so the entry point must always exit 0.
 * (I/O errors such as disk-full from appendFileSync are not suppressed.)
 */
export function runHook(opts: HookOptions): HookResult {
  const empty: HookResult = { stdout: '' };

  let parsed: unknown;
  try {
    parsed = JSON.parse(opts.stdin);
  } catch {
    return empty;
  }
  const payload = asRecord(parsed);
  if (payload === null) return empty;

  const sessionId = payload.session_id;
  if (typeof sessionId !== 'string' || sessionId.length === 0) return empty;

  // Codex (derive) path: self-register the worker meta on the first event for
  // this sid, since csd could not pre-write it at launch (it did not know the
  // id codex would mint). The claude path leaves `baked` undefined and so keeps
  // the no-op-without-meta behavior below.
  if (
    opts.baked !== undefined &&
    !existsSync(metaPath(opts.workerDir, sessionId))
  ) {
    const transcriptPath = asString(payload.transcript_path);
    writeMeta(opts.workerDir, {
      tmux_name: opts.baked.tmuxName,
      session_id: sessionId,
      cwd: opts.baked.cwd,
      harness: 'codex',
      ...(transcriptPath.length > 0 ? { transcript_path: transcriptPath } : {}),
    });
  }

  // Only emit for managed worker sessions.
  if (!existsSync(metaPath(opts.workerDir, sessionId))) return empty;

  const hookEventName = asString(payload.hook_event_name);
  const event = EVENT_MAP[hookEventName];
  // Unrecognized event name: keep the events file clean and typed.
  if (event === undefined) return empty;

  const ts = opts.now();
  const worker = buildEvent(event, ts, payload);

  appendEvent(eventsPath(opts.workerDir, sessionId), worker);

  return { stdout: '', appended: worker };
}

function buildEvent(
  event: EventName,
  ts: string,
  payload: Record<string, unknown>,
): WorkerEvent {
  switch (event) {
    case 'session_start': {
      const cwd = asString(payload.cwd);
      return cwd.length > 0 ? { event, ts, cwd } : { event, ts };
    }
    case 'pre_tool_use': {
      const toolInput = payload.tool_input;
      return {
        event,
        ts,
        tool: asString(payload.tool_name),
        tool_input:
          typeof toolInput === 'object' && toolInput !== null ? toolInput : {},
      };
    }
    case 'post_tool_use':
      return { event, ts, tool: asString(payload.tool_name) };
    case 'stop': {
      const stopHookActive =
        typeof payload.stop_hook_active === 'boolean'
          ? payload.stop_hook_active
          : undefined;
      const tasks = backgroundTasks(payload.background_tasks);
      const crons = sessionCrons(payload.session_crons);
      return {
        event,
        ts,
        ...terminalEvidence(payload),
        ...(stopHookActive === undefined
          ? {}
          : { stop_hook_active: stopHookActive }),
        ...(tasks === undefined ? {} : { background_tasks: tasks }),
        ...(crons === undefined ? {} : { session_crons: crons }),
      };
    }
    case 'stop_failure': {
      const errorDetails = boundedString(payload.error_details);
      return {
        event,
        ts,
        ...terminalEvidence(payload),
        error: asString(payload.error),
        ...(errorDetails === undefined ? {} : { error_details: errorDetails }),
      };
    }
    default:
      return { event, ts };
  }
}

/**
 * Reads all of stdin, resolving the empty string on a 5s timeout. Without the
 * timeout, a caller that fails to close stdin would hang the hook forever,
 * leaking processes on every event (issue #9).
 */
function readStdin(timeoutMs = 5000): Promise<string> {
  return new Promise((resolve) => {
    let data = '';
    let done = false;
    const finish = (value: string) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      resolve(value);
    };
    const timer = setTimeout(() => finish(data), timeoutMs);
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', (chunk) => {
      data += chunk;
    });
    process.stdin.on('end', () => finish(data));
    process.stdin.on('error', () => finish(data));
  });
}

async function main(): Promise<void> {
  const stdin = await readStdin();

  // Codex's config.toml bakes `<tmux_name> <cwd> <worker_dir>` as positional
  // args (claude's hooks.json passes none). When all three are present, take the
  // derive path: self-register the meta and use the baked worker dir (the worker
  // env does not carry CSD_WORKER_DIR). An empty worker_dir means no-op, mirroring
  // the bash hook's `[ -z "$WD" ] && exit 0`.
  const args = process.argv.slice(2);
  let baked: { tmuxName: string; cwd: string } | undefined;
  let dir = workerDir();
  if (args.length >= 3) {
    const [tmuxName = '', cwd = '', bakedWorkerDir = ''] = args;
    if (bakedWorkerDir.length === 0) {
      process.exit(0);
    }
    baked = { tmuxName, cwd };
    dir = bakedWorkerDir;
  }

  const result = runHook({
    stdin,
    workerDir: dir,
    now: () => isoSecondsUtc(),
    baked,
  });
  if (result.stdout.length > 0) {
    process.stdout.write(`${result.stdout}\n`);
  }
  process.exit(0);
}

// Run main() only when executed as the bundled CLI (`node dist/emit-event.cjs`).
// In the tsup CJS bundle `require.main === module` is true only then; under
// vitest's ESM import of this source `module`/`require` are not the CJS entry,
// so main() does not fire and no stdin read happens during tests.
if (
  typeof require !== 'undefined' &&
  typeof module !== 'undefined' &&
  require.main === module
) {
  void main();
}
