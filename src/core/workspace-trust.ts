import { createHash, randomUUID } from 'node:crypto';
import {
  chmodSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  renameSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { join } from 'node:path';

interface WorkspaceTrustGrant {
  version: 1;
  cwd: string;
}

export function workspaceTrustRoot(home: string): string {
  return join(home, '.claude', '.claude-session-driver', 'workspace-trust');
}

function workspaceKey(canonicalCwd: string): string {
  return createHash('sha256').update(canonicalCwd).digest('hex');
}

export function workspaceTrustGrantPath(
  home: string,
  canonicalCwd: string,
): string {
  return join(workspaceTrustRoot(home), `${workspaceKey(canonicalCwd)}.json`);
}

/** Read one exact hashed grant. Never scans or exposes other workspace paths. */
export function hasWorkspaceTrustGrant(
  home: string,
  canonicalCwd: string,
): boolean {
  const path = workspaceTrustGrantPath(home, canonicalCwd);
  try {
    const stat = lstatSync(path);
    if (!stat.isFile() || (stat.mode & 0o077) !== 0) return false;
    const value: unknown = JSON.parse(readFileSync(path, 'utf8'));
    if (typeof value !== 'object' || value === null) return false;
    const grant = value as Partial<WorkspaceTrustGrant>;
    return grant.version === 1 && grant.cwd === canonicalCwd;
  } catch {
    return false;
  }
}

/** Atomically replace one per-workspace grant with owner-only permissions. */
export function grantWorkspaceTrust(home: string, canonicalCwd: string): void {
  const root = workspaceTrustRoot(home);
  mkdirSync(root, { recursive: true, mode: 0o700 });
  if (!lstatSync(root).isDirectory()) {
    throw new Error(`Workspace trust root is not a directory: ${root}`);
  }
  chmodSync(root, 0o700);

  const path = workspaceTrustGrantPath(home, canonicalCwd);
  const temporary = join(
    root,
    `.${workspaceKey(canonicalCwd)}.${randomUUID()}.tmp`,
  );
  const grant: WorkspaceTrustGrant = { version: 1, cwd: canonicalCwd };
  try {
    writeFileSync(temporary, `${JSON.stringify(grant)}\n`, {
      flag: 'wx',
      mode: 0o600,
    });
    renameSync(temporary, path);
  } finally {
    rmSync(temporary, { force: true });
  }
}
