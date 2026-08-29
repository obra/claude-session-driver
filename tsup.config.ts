import { defineConfig } from 'tsup';

// tsup applies `format` per-config, so we ship TWO configs. The CLI and the
// Claude/Codex hook run via `node dist/*.cjs` (CJS). The pi extension is loaded
// by pi's jiti/ESM loader (`pi -e dist/pi-extension.mjs`), so it must be ESM —
// tsup bundles it self-contained (events/event-log/paths/worker-store inlined),
// with NO runtime require of the other dist bundles. Only the CJS config has
// `clean: true`; it owns wiping dist (a second clean would race-delete the
// first config's output).
//
// `dist/csd.cjs` also has to run as a standalone script — the consent-gate
// error prints its path directly (`<csdPath> grant-consent`), not `node
// <csdPath> grant-consent` (src/commands/launch.ts). That needs BOTH a
// shebang (banner, below) and the execute bit (onSuccess, below) or the
// printed instruction fails: no exec bit -> `Permission denied`; exec bit but
// no shebang -> the kernel hands the bundle to /bin/sh, which chokes on the
// first line of JS.
export default defineConfig([
  {
    entry: {
      csd: 'src/cli.ts',
      'emit-event': 'src/hooks/emit-event.ts',
    },
    outDir: 'dist',
    target: 'node22',
    clean: true,
    splitting: false,
    format: ['cjs'],
    outExtension: () => ({ js: '.cjs' }),
    banner: { js: '#!/usr/bin/env node' },
    // esbuild happens to chmod +x an output that starts with a shebang, so
    // this alone gets us most of the way there — but that's an esbuild
    // implementation detail, not a tsup contract, so don't rely on it
    // silently. Set the bit explicitly as a backstop; `dist:check` (which
    // rebuilds and diffs dist/) will fail the build if either mechanism ever
    // regresses.
    onSuccess: 'chmod +x dist/csd.cjs',
  },
  {
    entry: {
      'pi-extension': 'src/pi-extension/index.ts',
    },
    outDir: 'dist',
    target: 'node22',
    clean: false,
    splitting: false,
    format: ['esm'],
    outExtension: () => ({ js: '.mjs' }),
    treeshake: true,
  },
]);
