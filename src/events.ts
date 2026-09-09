export interface BackgroundTaskEvidence {
  id?: string;
  type?: string;
  status?: string;
}

export interface SessionCronEvidence {
  id?: string;
  schedule?: string;
  recurring?: boolean;
  prompt?: string;
}

interface TerminalEvidence {
  prompt_id?: string;
  transcript_path?: string;
  last_assistant_message?: string;
}

export type WorkerEvent =
  | { event: 'session_start'; ts: string; cwd?: string }
  | { event: 'user_prompt_submit'; ts: string }
  | { event: 'pre_tool_use'; ts: string; tool: string; tool_input: unknown }
  | { event: 'post_tool_use'; ts: string; tool: string }
  | ({
      event: 'stop';
      ts: string;
      stop_hook_active?: boolean;
      background_tasks?: BackgroundTaskEvidence[];
      session_crons?: SessionCronEvidence[];
    } & TerminalEvidence)
  | ({
      event: 'stop_failure';
      ts: string;
      error: string;
      error_details?: string;
    } & TerminalEvidence)
  | { event: 'session_end'; ts: string };

export type EventName = WorkerEvent['event'];

export const EVENT_NAMES: readonly EventName[] = [
  'session_start',
  'user_prompt_submit',
  'pre_tool_use',
  'post_tool_use',
  'stop',
  'stop_failure',
  'session_end',
];

export function serializeEvent(e: WorkerEvent): string {
  return JSON.stringify(e);
}

export function parseEvent(line: string): WorkerEvent | null {
  let v: unknown;
  try {
    v = JSON.parse(line);
  } catch {
    return null;
  }
  if (typeof v !== 'object' || v === null) return null;
  const event = (v as { event?: unknown }).event;
  if (typeof event !== 'string' || !EVENT_NAMES.includes(event as EventName))
    return null;
  return v as WorkerEvent;
}
