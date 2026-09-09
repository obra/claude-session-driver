import {
  chmodSync,
  existsSync,
  lstatSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import {
  grantWorkspaceTrust,
  hasWorkspaceTrustGrant,
  workspaceTrustGrantPath,
  workspaceTrustRoot,
} from '../src/core/workspace-trust.js';

function tmpDir(prefix: string): string {
  return mkdtempSync(join(tmpdir(), prefix));
}

describe('workspace trust storage', () => {
  let home: string;
  let cwd: string;

  beforeEach(() => {
    home = tmpDir('csd-trust-home-');
    cwd = tmpDir('csd-trust-cwd-');
  });

  afterEach(() => {
    rmSync(home, { recursive: true });
    rmSync(cwd, { recursive: true });
  });

  it('atomically stores one hashed canonical-path grant with private modes', () => {
    grantWorkspaceTrust(home, cwd);
    const root = workspaceTrustRoot(home);
    const path = workspaceTrustGrantPath(home, cwd);

    expect(hasWorkspaceTrustGrant(home, cwd)).toBe(true);
    expect(existsSync(join(home, '.claude.json'))).toBe(false);
    expect(readdirSync(root)).toEqual([basename(path)]);
    expect(basename(path)).toMatch(/^[0-9a-f]{64}\.json$/);
    expect(basename(path)).not.toContain(basename(cwd));
    expect(readFileSync(path, 'utf8')).toBe(
      `${JSON.stringify({ version: 1, cwd })}\n`,
    );
    expect(lstatMode(root) & 0o777).toBe(0o700);
    expect(lstatMode(path) & 0o777).toBe(0o600);
  });

  it('is idempotent and leaves no temporary grant file', () => {
    grantWorkspaceTrust(home, cwd);
    grantWorkspaceTrust(home, cwd);
    expect(readdirSync(workspaceTrustRoot(home))).toEqual([
      basename(workspaceTrustGrantPath(home, cwd)),
    ]);
  });

  it('fails closed for another workspace or a permissive/tampered grant', () => {
    grantWorkspaceTrust(home, cwd);
    expect(hasWorkspaceTrustGrant(home, `${cwd}-other`)).toBe(false);

    const path = workspaceTrustGrantPath(home, cwd);
    chmodSync(path, 0o644);
    expect(hasWorkspaceTrustGrant(home, cwd)).toBe(false);
  });

  it('supports a per-launch home-directory prompt through the same grant', () => {
    grantWorkspaceTrust(home, home);
    expect(hasWorkspaceTrustGrant(home, home)).toBe(true);
    expect(hasWorkspaceTrustGrant(home, cwd)).toBe(false);
  });
});

function lstatMode(path: string): number {
  return lstatSync(path).mode;
}
