import {
  grantWorkspaceTrust,
  hasWorkspaceTrustGrant,
} from '../core/workspace-trust.js';
import type { CommandContext, CommandResult } from './context.js';
import { resolveCwd } from './launch.js';

export interface GrantWorkspaceTrustOpts {
  isInteractive: boolean;
  warn?: (text: string) => void;
  /** Return the exact, untrimmed line typed by the user. */
  confirm: () => Promise<string>;
}

export async function cmdGrantWorkspaceTrust(
  ctx: CommandContext,
  cwd: string,
  opts: GrantWorkspaceTrustOpts,
): Promise<CommandResult> {
  const resolved = resolveCwd(cwd);
  if (typeof resolved !== 'string') return resolved;
  const canonicalCwd = resolved;

  if (hasWorkspaceTrustGrant(ctx.home, canonicalCwd)) {
    return {
      stdout: `Workspace trust already granted for: ${canonicalCwd}`,
      code: 0,
    };
  }

  if (!opts.isInteractive) {
    return {
      stderr:
        'Error: grant-workspace-trust requires an interactive terminal so the user can confirm the canonical path.',
      code: 1,
    };
  }

  opts.warn?.(
    [
      'Claude may ask whether to trust this workspace before loading project-controlled instructions, hooks, or settings.',
      'CSD will press Enter only when that prompt appears for this exact canonical path:',
      canonicalCwd,
      'This command writes only CSD state and never edits ~/.claude.json; after CSD accepts a future prompt, Claude Code controls its own trust persistence.',
    ].join('\n'),
  );

  const confirmation = await opts.confirm();
  if (confirmation !== canonicalCwd) {
    return {
      stderr: `Workspace trust not granted. Type the exact canonical path: ${canonicalCwd}`,
      code: 1,
    };
  }

  grantWorkspaceTrust(ctx.home, canonicalCwd);
  return {
    stdout: `Workspace trust granted for: ${canonicalCwd}`,
    code: 0,
  };
}
