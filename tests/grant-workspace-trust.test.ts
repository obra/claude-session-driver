import { mkdtempSync, realpathSync, rmSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import type { CommandContext } from '../src/commands/context.js';
import { cmdGrantWorkspaceTrust } from '../src/commands/grant-workspace-trust.js';
import { makeTmux } from '../src/core/tmux.js';
import { hasWorkspaceTrustGrant } from '../src/core/workspace-trust.js';
import { getDriver } from '../src/harness/registry.js';

function tmpDir(prefix: string): string {
  return mkdtempSync(join(tmpdir(), prefix));
}

function makeCtx(home: string): CommandContext {
  return {
    workerDir: join(home, 'workers'),
    home,
    tmux: makeTmux(async () => ({ stdout: '', stderr: '', code: 0 })),
    driver: getDriver('claude'),
  };
}

describe('cmdGrantWorkspaceTrust', () => {
  let home: string;
  let cwd: string;

  beforeEach(() => {
    home = tmpDir('csd-gwt-home-');
    cwd = tmpDir('csd-gwt-cwd-');
  });

  afterEach(() => {
    rmSync(home, { recursive: true });
    rmSync(cwd, { recursive: true });
  });

  it('shows and requires the exact canonical realpath before granting', async () => {
    const alias = join(home, 'workspace-alias');
    symlinkSync(cwd, alias);
    const canonical = realpathSync(cwd);
    const events: string[] = [];
    const result = await cmdGrantWorkspaceTrust(makeCtx(home), alias, {
      isInteractive: true,
      warn: (text) => events.push(`warn:${text}`),
      confirm: async () => {
        events.push('confirm');
        return canonical;
      },
    });

    expect(result.code).toBe(0);
    expect(result.stdout).toContain(canonical);
    expect(events[0]).toContain(canonical);
    expect(events[0]).toContain('writes only CSD state');
    expect(events[0]).toContain(
      'Claude Code controls its own trust persistence',
    );
    expect(events[1]).toBe('confirm');
    expect(hasWorkspaceTrustGrant(home, canonical)).toBe(true);
    expect(hasWorkspaceTrustGrant(home, alias)).toBe(false);
  });

  it('rejects yes or a non-exact path instead of weakening confirmation', async () => {
    const canonical = realpathSync(cwd);
    const result = await cmdGrantWorkspaceTrust(makeCtx(home), cwd, {
      isInteractive: true,
      confirm: async () => 'yes',
    });
    expect(result.code).toBe(1);
    expect(result.stderr).toContain(`exact canonical path: ${canonical}`);
    expect(hasWorkspaceTrustGrant(home, canonical)).toBe(false);
  });

  it('rejects non-interactive invocation without prompting or writing', async () => {
    let prompted = false;
    const result = await cmdGrantWorkspaceTrust(makeCtx(home), cwd, {
      isInteractive: false,
      confirm: async () => {
        prompted = true;
        return realpathSync(cwd);
      },
    });
    expect(result.code).toBe(1);
    expect(result.stderr).toContain('interactive terminal');
    expect(prompted).toBe(false);
    expect(hasWorkspaceTrustGrant(home, realpathSync(cwd))).toBe(false);
  });

  it('grants the canonical home path and reports an existing grant idempotently', async () => {
    const canonicalHome = realpathSync(home);
    const first = await cmdGrantWorkspaceTrust(makeCtx(home), home, {
      isInteractive: true,
      confirm: async () => canonicalHome,
    });
    expect(first.code).toBe(0);
    expect(hasWorkspaceTrustGrant(home, canonicalHome)).toBe(true);

    const second = await cmdGrantWorkspaceTrust(makeCtx(home), home, {
      isInteractive: false,
      confirm: async () => '',
    });
    expect(second.code).toBe(0);
    expect(second.stdout).toContain('already granted');
  });

  it('rejects a missing workspace before prompting', async () => {
    let prompted = false;
    const result = await cmdGrantWorkspaceTrust(
      makeCtx(home),
      join(cwd, 'missing'),
      {
        isInteractive: true,
        confirm: async () => {
          prompted = true;
          return '';
        },
      },
    );
    expect(result.code).toBe(1);
    expect(result.stderr).toContain('does not exist');
    expect(prompted).toBe(false);
  });
});
