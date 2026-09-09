import { describe, expect, it } from 'vitest';
import { renderCsdCommand, runnableCsd } from '../src/core/csd-command.js';

describe('runnable CSD command rendering', () => {
  it('node-prefixes and quotes a JavaScript bundle path', () => {
    expect(runnableCsd('/plugin path/dist/csd.cjs')).toBe(
      "node '/plugin path/dist/csd.cjs'",
    );
  });

  it('uses a non-JavaScript wrapper directly', () => {
    expect(runnableCsd('/usr/local/bin/csd')).toBe('/usr/local/bin/csd');
  });

  it('shell-quotes every rendered argument', () => {
    expect(
      renderCsdCommand('/plugin path/dist/csd.cjs', [
        'grant-workspace-trust',
        "/workspace/it's here",
      ]),
    ).toBe(
      "node '/plugin path/dist/csd.cjs' grant-workspace-trust '/workspace/it'\\''s here'",
    );
  });
});
