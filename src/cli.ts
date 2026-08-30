import { homedir } from 'node:os';
import { join, resolve } from 'node:path';
import { createInterface } from 'node:readline';
import { cmdAdopt } from './commands/adopt.js';
import type { CommandContext, CommandResult } from './commands/context.js';
import { cmdConverse } from './commands/converse.js';
import { cmdEventsFile } from './commands/events-file.js';
import { cmdGrantConsent } from './commands/grant-consent.js';
import { cmdGrantWorkspaceTrust } from './commands/grant-workspace-trust.js';
import { cmdHandoff } from './commands/handoff.js';
import type { BootstrapOpts } from './commands/launch.js';
import { cmdLaunch } from './commands/launch.js';
import { cmdList } from './commands/list.js';
import { cmdPrune } from './commands/prune.js';
import { cmdReadEvents, followEvents } from './commands/read-events.js';
import { cmdReadTurn } from './commands/read-turn.js';
import { cmdSend } from './commands/send.js';
import { cmdSessionId } from './commands/session-id.js';
import { cmdStatus } from './commands/status.js';
import { cmdStop } from './commands/stop.js';
import { cmdWaitForTurn } from './commands/wait-for-turn.js';
import { workerDir } from './core/paths.js';
import { tmux } from './core/tmux.js';
import {
  readHarnessMarker,
  readMeta,
  resolveSession,
} from './core/worker-store.js';
import { getDriver } from './harness/registry.js';

/** Writers the dispatcher prints through; tests inject capturing functions. */
export interface Io {
  out: (s: string) => void;
  err: (s: string) => void;
}

const realIo: Io = {
  out: (s) => process.stdout.write(s),
  err: (s) => process.stderr.write(s),
};

const TOP_LEVEL_SUBS = [
  'launch',
  'adopt',
  'list',
  'prune',
  'grant-consent',
  'grant-workspace-trust',
  'help',
];
const PER_WORKER_SUBS = [
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
];

/**
 * The user contract. Ported from the bash `usage()` heredoc, updated for the
 * TypeScript multi-harness tool: the `--harness` launch flag, the
 * `/tmp/csd-workers` default worker dir (the back-compat symlink keeps the old
 * `/tmp/claude-workers` path working), and the per-harness env vars.
 */
const USAGE = `Usage: csd <subcommand> [args...]
       csd --worker <name> <subcommand> [args...]

A worker is a coding-agent session (Claude Code, Codex, or Pi) in a tmux pane
that emits lifecycle events the controller observes. \`csd launch\` prints a
*shim path* on stdout (deterministic at /tmp/csd-workers/bin/<tmux-name>) — run
that shim for all per-worker subcommands. \`csd stop\` removes the shim along
with the worker's state. The per-worker surface is identical across harnesses.

Top-level subcommands:
  launch [--harness <claude|codex|pi>] <tmux-name> <cwd> [-- harness-args...]
                       Bootstrap a worker (harness defaults to claude); shim
                       path on stdout, panel on stderr
  adopt <tmux-name> <cwd> <session-id> [-- claude-args...]
                       Re-adopt an existing Claude session as a driveable
                       worker via \`claude --resume <session-id>\` (claude-only;
                       codex/pi mint their own ids and offer no resume-by-id).
                       Restores a worker after a reboot/crash wiped
                       /tmp/csd-workers while the conversation transcript
                       survived. If a tmux session named <tmux-name> already
                       exists (e.g. restored by tmux-resurrect), respawns its
                       pane in place; else opens a new one. Shim path on stdout,
                       panel on stderr
  list [--all] [<pattern>]
                       Enumerate workers (default: skip workers whose tmux is
                       gone). Optional pattern filters by tmux-name substring
  prune                Remove the runtime state of all \`gone\` workers (tmux
                       session dead); live workers are untouched
  grant-consent        One-time consent for running workers with permissions
                       bypassed (--dangerously-skip-permissions et al.)
  grant-workspace-trust <cwd>
                       Interactively grant CSD permission to accept Claude's
                       workspace-trust prompt for one canonical directory
  help                 Show this message

Per-worker subcommands (require --worker, supplied by the shim):
  converse [--with-turn] <prompt> [timeout=120]
                       Send prompt, wait for turn, return assistant text.
                       --with-turn returns the full markdown turn instead
  send <prompt>        Send a prompt without waiting for the turn
  wait-for-turn [timeout=60] [--after-line N]
                       Block until the next stop, stop_failure, OR session_end.
                       By default the baseline is the events file's current end,
                       so it waits for a NEW turn-end; pass --after-line N to wait
                       for the first turn-end after line N (a baseline captured
                       earlier). Exit 124 prints retry_after_line: N; reuse that
                       N with --after-line so a late terminal event stays visible
  status               idle | working | terminated | gone | unknown
  read-events [--last N] [--type T] [--follow]
                       Read the event JSONL stream. With --follow, --last N caps
                       the replayed backlog to the last N events before tailing
                       (--last 0 = only NEW events; omit = replay everything)
  read-turn [--full]   Last turn as markdown. Without --full, tool results
                       are truncated to 5 lines; --full shows them complete
  stop                 /exit, clean up meta + events + shim
  handoff              Print tmux-attach instructions for a human
  session-id           Print the worker's session id
  events-file          Print the absolute path to the events JSONL

Exit codes:
  0   Success
  1   Operational error
  2   CLI usage error
  3   Proven API-error turn
  4   Reserved for interruption
  124 Wait budget expired without terminal evidence

Environment variables:
  CSD_CLAUDE_BIN / CSD_CODEX_BIN / CSD_PI_BIN
                       Path to each harness binary (defaults: claude / codex / pi,
                       resolved via PATH). Set when the binary is not on PATH or you
                       want to pin a specific version.
  CSD_CODEX_MODEL / CSD_PI_MODEL
                       Optional model override for codex / pi workers. Unset = the
                       harness default (codex: gpt-5.5; pi: its configured default).
  CSD_CONVERSE_DIAG_FILE
                       When set, \`converse\` writes a post-mortem diagnostic (ps tree +
                       tmux capture-pane + worker session JSONL tail + csd events tail)
                       to this path on timeout, then emits "csd-diagnostic: <path>" to
                       stderr. Overwritten on each timeout. Unset = no diagnostic file.
  CSD_WORKER_DIR       Directory for worker runtime state (meta/events/shim).
                       Default: /tmp/csd-workers.
  CSD_SUBMIT_TIMEOUT / CSD_SUBMIT_RETRY_INTERVAL
                       \`send\`: seconds to wait for the worker to confirm a pasted
                       prompt (default 10) and seconds between retry-Enter resends
                       (default 2).
  CSD_REGISTER_TIMEOUT Seconds the FIRST \`send\` to a derive worker (codex/pi) waits
                       for it to self-register its session id (default 15).
  HOME                 Used to locate ~/.claude/projects/<encoded-cwd>/<sid>.jsonl and
                       the one-time consent file (~/.claude/.claude-session-driver-consent).
`;

/** A code-2 dispatch error: print `message` to stderr, return 2. */
interface DispatchError {
  message: string;
  code: number;
}

function err(message: string, code = 2): DispatchError {
  return { message, code };
}

/**
 * Parse a leading `--worker <val>` / `--worker=val` (bash csd:950-963). Returns
 * the worker (or undefined) plus the remaining argv after the worker flag, or a
 * DispatchError when `--worker` is given with no value.
 */
function parseWorker(
  argv: string[],
): { worker?: string; rest: string[] } | DispatchError {
  let worker: string | undefined;
  let i = 0;
  while (i < argv.length) {
    const a = argv[i] ?? '';
    if (a === '--worker') {
      if (i + 1 >= argv.length) {
        return err('Error: --worker requires a value');
      }
      worker = argv[i + 1];
      i += 2;
    } else if (a.startsWith('--worker=')) {
      worker = a.slice('--worker='.length);
      i += 1;
    } else {
      break;
    }
  }
  // bash uses `[ -z "$WORKER" ]`: an empty worker (`--worker=` or `--worker ""`)
  // is treated as MISSING, not as a literal worker named '' (which would yield
  // exit 1 "no worker known as ''" instead of the exit 2 "required" error).
  return { worker: worker ? worker : undefined, rest: argv.slice(i) };
}

/**
 * The harness id for a per-worker command's `worker`. Read from the worker meta
 * (`harness`) once it exists; during a derive worker's pre-registration window
 * (codex, before its hook self-registers the meta) fall back to the sidecar
 * `<tmux_name>.harness` marker launch wrote. Defaults to claude when neither is
 * present (an unknown worker — the command itself reports that).
 */
function resolveWorkerHarness(dir: string, worker: string): string {
  const sid = resolveSession(dir, worker);
  if (sid !== null) {
    const meta = readMeta(dir, sid);
    if (meta?.harness) return meta.harness;
  }
  return readHarnessMarker(dir, worker) ?? 'claude';
}

/**
 * Build the CommandContext: real tmux and the per-worker harness driver. For
 * per-worker commands the driver is resolved from the worker's meta/sidecar so
 * codex workers drive the codex transcript/send paths; top-level commands
 * (launch/adopt resolve their own driver) get claude as a harmless default.
 */
function buildContext(worker?: string): CommandContext {
  const dir = workerDir();
  const harness =
    worker !== undefined ? resolveWorkerHarness(dir, worker) : 'claude';
  return {
    workerDir: dir,
    home: process.env.HOME ?? homedir(),
    tmux,
    driver: getDriver(harness),
  };
}

/**
 * The bootstrap opts launch/adopt need. In the tsup CJS bundle `__dirname` is
 * the `dist/` directory, so the plugin root is its parent and `csd.cjs` sits
 * beside this file.
 */
function bootstrapOpts(): BootstrapOpts {
  const csdEntry = join(__dirname, 'csd.cjs');
  return {
    pluginDir: process.env.CLAUDE_PLUGIN_ROOT ?? resolve(__dirname, '..'),
    csdEntry,
    csdPath: process.env.CSD_PATH ?? csdEntry,
  };
}

/**
 * Read the first line from `input` (default stdin), resolving the trimmed
 * string. On EOF without a line (empty pipe), resolves '' so the caller does not
 * hang forever waiting for a line that never arrives.
 *
 * Piped (non-TTY) stdin is the subtle case: readline can emit `'close'` in the
 * same tick as the buffered `'line'`, and a naive `close -> resolve('')` races
 * ahead of the line, dropping it — so `echo yes | csd grant-consent` would deny
 * consent (a parity regression; bash `read -r` reads it fine). We capture the
 * first line and resolve with whatever we captured on close, so a received line
 * always wins.
 */
export function readLine(
  input: NodeJS.ReadableStream = process.stdin,
): Promise<string> {
  return new Promise((res) => {
    const rl = createInterface({ input });
    let captured: string | null = null;
    rl.once('line', (line) => {
      captured = line.trim();
      rl.close();
    });
    rl.once('close', () => res(captured ?? ''));
  });
}

/** Read the first line without trimming; workspace paths must match exactly. */
export function readExactLine(
  input: NodeJS.ReadableStream = process.stdin,
): Promise<string> {
  return new Promise((res) => {
    const rl = createInterface({ input });
    let captured: string | null = null;
    rl.once('line', (line) => {
      captured = line;
      rl.close();
    });
    rl.once('close', () => res(captured ?? ''));
  });
}

/** Parse `launch [--harness <id>] <tmux-name> <cwd> [-- harness-args...]`. */
function parseLaunchArgs(
  argv: string[],
):
  | { tmuxName: string; cwd: string; extraArgs: string[]; harness: string }
  | DispatchError {
  const usage = 'Usage: launch <tmux-name> <cwd> [-- claude-args...]';
  const positionals: string[] = [];
  let harness = 'claude';
  let extraArgs: string[] = [];
  let i = 0;
  while (i < argv.length) {
    const a = argv[i] ?? '';
    if (a === '--') {
      extraArgs = argv.slice(i + 1);
      break;
    }
    if (a === '--harness') {
      const value = argv[i + 1];
      if (value === undefined) {
        return err('Error: --harness expects a value for launch');
      }
      // Validate the id against the driver registry at parse time so an unknown
      // harness yields a clean code-2 error instead of a stack trace from
      // getDriver() inside cmdLaunch.
      try {
        getDriver(value);
      } catch (e) {
        return err((e as Error).message);
      }
      harness = value;
      i += 2;
      continue;
    }
    positionals.push(a);
    i += 1;
  }
  const [tmuxName, cwd] = positionals;
  if (tmuxName === undefined || cwd === undefined) return err(usage);
  return { tmuxName, cwd, extraArgs, harness };
}

/** Parse `adopt <tmux-name> <cwd> <session-id> [-- claude-args...]`. */
function parseAdoptArgs(
  argv: string[],
):
  | { tmuxName: string; cwd: string; sessionId: string; extraArgs: string[] }
  | DispatchError {
  const usage =
    'Usage: adopt <tmux-name> <cwd> <session-id> [-- claude-args...]';
  let rest = argv;
  let extraArgs: string[] = [];
  const sep = rest.indexOf('--');
  if (sep !== -1) {
    extraArgs = rest.slice(sep + 1);
    rest = rest.slice(0, sep);
  }
  const [tmuxName, cwd, sessionId] = rest;
  if (tmuxName === undefined || cwd === undefined || sessionId === undefined) {
    return err(usage);
  }
  return { tmuxName, cwd, sessionId, extraArgs };
}

/** Print a CommandResult and return its code; each stream gets a trailing newline. */
function emit(io: Io, result: CommandResult): number {
  if (result.stdout !== undefined && result.stdout.length > 0) {
    io.out(`${result.stdout}\n`);
  }
  if (result.stderr !== undefined && result.stderr.length > 0) {
    io.err(`${result.stderr}\n`);
  }
  return result.code;
}

/**
 * The CLI dispatcher. Parses `--worker`, validates the subcommand against the
 * top-level/per-worker sets, builds the CommandContext, parses the per-command
 * args, runs the matching command, and prints its result. Returns the exit code
 * (never calls process.exit — the entry point does that).
 */
export async function run(argv: string[], io: Io = realIo): Promise<number> {
  const parsed = parseWorker(argv);
  if ('code' in parsed) {
    io.err(`${parsed.message}\n`);
    return parsed.code;
  }
  const { worker, rest } = parsed;
  const sub = rest[0];
  const args = rest.slice(1);

  if (sub === undefined) {
    io.err(USAGE);
    return 2;
  }

  if (TOP_LEVEL_SUBS.includes(sub)) {
    if (worker !== undefined) {
      io.err(
        `Error: --worker is not valid for '${sub}' (top-level subcommand)\n`,
      );
      return 2;
    }
  } else if (PER_WORKER_SUBS.includes(sub)) {
    if (worker === undefined) {
      io.err(`Error: --worker <name> is required for '${sub}'\n`);
      return 2;
    }
  } else {
    io.err(`Error: unknown subcommand '${sub}'\n`);
    io.err(USAGE);
    return 2;
  }

  if (sub === 'help') {
    io.out(USAGE);
    return 0;
  }

  const ctx = buildContext(worker);
  // PER_WORKER_SUBS validation above guarantees `worker` is set for those subs.
  const w = worker as string;

  switch (sub) {
    case 'grant-consent':
      return emit(
        io,
        await cmdGrantConsent(ctx, {
          warn: (text) => io.out(`${text}\n`),
          confirm: () => grantConsentConfirm(io),
        }),
      );

    case 'grant-workspace-trust': {
      const [cwd, ...extra] = args;
      if (cwd === undefined || extra.length > 0) {
        io.err('Usage: grant-workspace-trust <cwd>\n');
        return 2;
      }
      return emit(
        io,
        await cmdGrantWorkspaceTrust(ctx, cwd, {
          isInteractive: process.stdin.isTTY === true,
          warn: (text) => io.out(`${text}\n`),
          confirm: () => grantWorkspaceTrustConfirm(io),
        }),
      );
    }

    case 'launch': {
      const parsedArgs = parseLaunchArgs(args);
      if ('code' in parsedArgs) {
        io.err(`${parsedArgs.message}\n`);
        return parsedArgs.code;
      }
      return emit(io, await cmdLaunch(ctx, parsedArgs, bootstrapOpts()));
    }

    case 'adopt': {
      const parsedArgs = parseAdoptArgs(args);
      if ('code' in parsedArgs) {
        io.err(`${parsedArgs.message}\n`);
        return parsedArgs.code;
      }
      return emit(io, await cmdAdopt(ctx, parsedArgs, bootstrapOpts()));
    }

    case 'list': {
      const opts = parseListArgs(args);
      if ('code' in opts) {
        io.err(`${opts.message}\n`);
        return opts.code;
      }
      return emit(io, await cmdList(ctx, opts));
    }

    case 'prune':
      return emit(io, await cmdPrune(ctx));

    case 'converse': {
      let withTurn = false;
      let i = 0;
      if (args[i] === '--with-turn') {
        withTurn = true;
        i += 1;
      }
      const prompt = args[i];
      if (prompt === undefined || prompt.trim() === '') {
        io.err('Usage: converse [--with-turn] <prompt> [timeout=120]\n');
        return 2;
      }
      let timeout = 120;
      if (args[i + 1] !== undefined) {
        timeout = Number(args[i + 1]);
        if (!Number.isFinite(timeout)) {
          io.err('Error: converse timeout must be a number\n');
          return 2;
        }
      }
      return emit(io, await cmdConverse(ctx, w, prompt, { withTurn, timeout }));
    }

    case 'send': {
      const prompt = args[0];
      if (prompt === undefined || prompt.trim() === '') {
        io.err('Usage: send <prompt-text>\n');
        return 2;
      }
      return emit(io, await cmdSend(ctx, w, prompt));
    }

    case 'wait-for-turn': {
      const opts = parseWaitForTurnArgs(args);
      if ('code' in opts) {
        io.err(`${opts.message}\n`);
        return opts.code;
      }
      return emit(io, await cmdWaitForTurn(ctx, w, opts));
    }

    case 'read-events': {
      const opts = parseReadEventsArgs(args);
      if ('code' in opts) {
        io.err(`${opts.message}\n`);
        return opts.code;
      }
      if (opts.follow) {
        return followStream(ctx, w, opts, io);
      }
      return emit(
        io,
        await cmdReadEvents(ctx, w, { last: opts.last, type: opts.type }),
      );
    }

    case 'read-turn': {
      const full = args[0] === '--full';
      return emit(io, await cmdReadTurn(ctx, w, { full }));
    }

    case 'status':
      return emit(io, await cmdStatus(ctx, w));

    case 'handoff':
      return emit(io, await cmdHandoff(ctx, w));

    case 'session-id':
      return emit(io, await cmdSessionId(ctx, w));

    case 'events-file':
      return emit(io, await cmdEventsFile(ctx, w));

    case 'stop':
      return emit(io, await cmdStop(ctx, w));

    default:
      // Unreachable: validated against PER_WORKER_SUBS/TOP_LEVEL_SUBS above.
      io.err(`Error: unknown subcommand '${sub}'\n`);
      return 2;
  }
}

/** Parse `list [--all] [<pattern>]`. */
function parseListArgs(
  argv: string[],
): { all?: boolean; pattern?: string } | DispatchError {
  let all = false;
  let pattern: string | undefined;
  for (const a of argv) {
    if (a === '--all') {
      all = true;
    } else if (a.startsWith('--')) {
      return err(`Error: unknown option '${a}' for list`);
    } else if (pattern !== undefined) {
      return err('Error: list takes at most one pattern argument');
    } else {
      pattern = a;
    }
  }
  return { all, pattern };
}

/** Parse `wait-for-turn [timeout=60] [--after-line N]`. */
function parseWaitForTurnArgs(
  argv: string[],
): { timeout?: number; afterLine?: number } | DispatchError {
  let timeout: number | undefined;
  let afterLine: number | undefined;
  let i = 0;
  while (i < argv.length) {
    const a = argv[i] ?? '';
    if (a === '--after-line') {
      const value = argv[i + 1];
      const n = value !== undefined ? Number(value) : Number.NaN;
      if (!Number.isFinite(n)) {
        return err('Error: --after-line expects a number for wait-for-turn');
      }
      afterLine = n;
      i += 2;
    } else if (/^[0-9]/.test(a)) {
      timeout = Number(a);
      i += 1;
    } else {
      return err(`Error: unknown option '${a}' for wait-for-turn`);
    }
  }
  return { timeout, afterLine };
}

interface ReadEventsArgs {
  last?: number;
  type?: string;
  follow: boolean;
}

/** Parse `read-events [--last N] [--type T] [--follow]`. */
function parseReadEventsArgs(argv: string[]): ReadEventsArgs | DispatchError {
  let last: number | undefined;
  let type: string | undefined;
  let follow = false;
  let i = 0;
  while (i < argv.length) {
    const a = argv[i] ?? '';
    if (a === '--last') {
      const value = argv[i + 1];
      const n = value !== undefined ? Number(value) : Number.NaN;
      if (!Number.isFinite(n)) {
        return err('Error: --last expects a number for read-events');
      }
      last = n;
      i += 2;
    } else if (a === '--type') {
      const value = argv[i + 1];
      // A missing value or a following flag (e.g. `--type --follow`) means the
      // type value is absent; do not swallow the next flag as the value.
      if (value === undefined || value.startsWith('--')) {
        return err('Error: --type expects a value for read-events');
      }
      type = value;
      i += 2;
    } else if (a === '--follow') {
      follow = true;
      i += 1;
    } else {
      return err(`Error: unknown option '${a}' for read-events`);
    }
  }
  return { last, type, follow };
}

/**
 * Stream events to stdout until SIGINT. followEvents emits lines WITHOUT a
 * trailing newline, so the sink appends one. Resolves 0 once aborted.
 *
 * Tests inject `signal`/`pollMs` to drive the stream deterministically (append a
 * line, assert it arrives, abort). In production neither is passed: an internal
 * AbortController is wired to SIGINT.
 */
export function followStream(
  ctx: CommandContext,
  worker: string,
  opts: { type?: string; last?: number; pollMs?: number },
  io: Io,
  signal?: AbortSignal,
): Promise<number> {
  const followOpts = { type: opts.type, last: opts.last, pollMs: opts.pollMs };
  if (signal !== undefined) {
    return followEvents(
      ctx,
      worker,
      followOpts,
      (line) => io.out(`${line}\n`),
      signal,
    ).then(() => 0);
  }
  const controller = new AbortController();
  const onSigint = () => controller.abort();
  process.on('SIGINT', onSigint);
  return followEvents(
    ctx,
    worker,
    followOpts,
    (line) => io.out(`${line}\n`),
    controller.signal,
  )
    .then(() => 0)
    .finally(() => process.off('SIGINT', onSigint));
}

/**
 * The interactive consent confirm: print the prompt (the command's preamble is
 * printed by the command BEFORE this runs), read a line from `input` (default
 * stdin), resolve true iff it is 'yes'. Works for both an interactive TTY and a
 * pipe (`echo yes | csd grant-consent`).
 */
export async function grantConsentConfirm(
  io: Io,
  input: NodeJS.ReadableStream = process.stdin,
): Promise<boolean> {
  io.out("Type 'yes' to grant consent:\n");
  const reply = await readLine(input);
  return reply === 'yes';
}

export async function grantWorkspaceTrustConfirm(
  io: Io,
  input: NodeJS.ReadableStream = process.stdin,
): Promise<string> {
  io.out('Type the exact canonical path shown above to confirm:\n');
  return readExactLine(input);
}

// Run the CLI only when executed as the bundled `node dist/csd.cjs`. In the
// tsup CJS bundle `require.main === module` is true only then; under vitest's
// ESM import of this source it is not, so run() does not fire during tests.
if (
  typeof require !== 'undefined' &&
  typeof module !== 'undefined' &&
  require.main === module
) {
  run(process.argv.slice(2))
    .then((c) => process.exit(c))
    .catch((e) => {
      process.stderr.write(`${e instanceof Error ? e.message : String(e)}\n`);
      process.exit(1);
    });
}
