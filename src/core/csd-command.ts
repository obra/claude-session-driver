import { shellQuote } from './shell.js';

/** Render the configured CSD entry as a copy-pasteable shell command. */
export function runnableCsd(csdPath: string): string {
  return /\.[cm]?js$/.test(csdPath)
    ? `node ${shellQuote(csdPath)}`
    : shellQuote(csdPath);
}

/** Render a complete CSD command with every argument shell-quoted. */
export function renderCsdCommand(csdPath: string, args: string[]): string {
  const renderedArgs = args.map(shellQuote).join(' ');
  return renderedArgs.length > 0
    ? `${runnableCsd(csdPath)} ${renderedArgs}`
    : runnableCsd(csdPath);
}
