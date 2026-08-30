"use strict";
var __defProp = Object.defineProperty;
var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
var __getOwnPropNames = Object.getOwnPropertyNames;
var __hasOwnProp = Object.prototype.hasOwnProperty;
var __export = (target, all) => {
  for (var name in all)
    __defProp(target, name, { get: all[name], enumerable: true });
};
var __copyProps = (to, from, except, desc) => {
  if (from && typeof from === "object" || typeof from === "function") {
    for (let key of __getOwnPropNames(from))
      if (!__hasOwnProp.call(to, key) && key !== except)
        __defProp(to, key, { get: () => from[key], enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable });
  }
  return to;
};
var __toCommonJS = (mod) => __copyProps(__defProp({}, "__esModule", { value: true }), mod);

// src/hooks/emit-event.ts
var emit_event_exports = {};
__export(emit_event_exports, {
  MAX_EVENT_TEXT_LENGTH: () => MAX_EVENT_TEXT_LENGTH,
  runHook: () => runHook
});
module.exports = __toCommonJS(emit_event_exports);
var import_node_fs4 = require("fs");

// src/core/event-log.ts
var import_node_fs = require("fs");

// src/events.ts
function serializeEvent(e) {
  return JSON.stringify(e);
}

// src/core/event-log.ts
function appendEvent(file, e) {
  (0, import_node_fs.appendFileSync)(file, `${serializeEvent(e)}
`);
}

// src/core/paths.ts
var import_node_fs2 = require("fs");
var DEFAULT_WORKER_DIR = "/tmp/csd-workers";
function workerDir() {
  return process.env.CSD_WORKER_DIR ?? DEFAULT_WORKER_DIR;
}
function eventsPath(dir, sid) {
  return `${dir}/${sid}.events.jsonl`;
}
function metaPath(dir, sid) {
  return `${dir}/${sid}.meta`;
}

// src/core/time.ts
function isoSecondsUtc(date = /* @__PURE__ */ new Date()) {
  return date.toISOString().replace(/\.\d{3}Z$/, "Z");
}

// src/core/worker-store.ts
var import_node_fs3 = require("fs");
var import_node_path = require("path");
function writeMeta(dir, meta) {
  (0, import_node_fs3.mkdirSync)(dir, { recursive: true });
  (0, import_node_fs3.writeFileSync)(metaPath(dir, meta.session_id), JSON.stringify(meta));
}

// src/hooks/emit-event.ts
var EVENT_MAP = {
  SessionStart: "session_start",
  Stop: "stop",
  StopFailure: "stop_failure",
  UserPromptSubmit: "user_prompt_submit",
  SessionEnd: "session_end",
  PreToolUse: "pre_tool_use",
  PostToolUse: "post_tool_use"
};
function asRecord(v) {
  return typeof v === "object" && v !== null ? v : null;
}
function asString(v) {
  return typeof v === "string" ? v : "";
}
var MAX_EVENT_TEXT_LENGTH = 8192;
function boundedString(v) {
  return typeof v === "string" ? v.slice(0, MAX_EVENT_TEXT_LENGTH) : void 0;
}
function optionalString(v) {
  return typeof v === "string" && v.length > 0 ? v : void 0;
}
function terminalEvidence(payload) {
  const promptId = optionalString(payload.prompt_id);
  const transcriptPath = optionalString(payload.transcript_path);
  const lastAssistantMessage = boundedString(payload.last_assistant_message);
  return {
    ...promptId === void 0 ? {} : { prompt_id: promptId },
    ...transcriptPath === void 0 ? {} : { transcript_path: transcriptPath },
    ...lastAssistantMessage === void 0 ? {} : { last_assistant_message: lastAssistantMessage }
  };
}
function backgroundTasks(v) {
  if (!Array.isArray(v)) return void 0;
  return v.flatMap((item) => {
    const record = asRecord(item);
    if (record === null) return [];
    const id = optionalString(record.id);
    const type = optionalString(record.type);
    const status = optionalString(record.status);
    return [
      {
        ...id === void 0 ? {} : { id },
        ...type === void 0 ? {} : { type },
        ...status === void 0 ? {} : { status }
      }
    ];
  });
}
function sessionCrons(v) {
  if (!Array.isArray(v)) return void 0;
  return v.flatMap((item) => {
    const record = asRecord(item);
    if (record === null) return [];
    const id = optionalString(record.id);
    const schedule = optionalString(record.schedule);
    const recurring = typeof record.recurring === "boolean" ? record.recurring : void 0;
    const prompt = boundedString(record.prompt);
    return [
      {
        ...id === void 0 ? {} : { id },
        ...schedule === void 0 ? {} : { schedule },
        ...recurring === void 0 ? {} : { recurring },
        ...prompt === void 0 ? {} : { prompt }
      }
    ];
  });
}
function runHook(opts) {
  const empty = { stdout: "" };
  let parsed;
  try {
    parsed = JSON.parse(opts.stdin);
  } catch {
    return empty;
  }
  const payload = asRecord(parsed);
  if (payload === null) return empty;
  const sessionId = payload.session_id;
  if (typeof sessionId !== "string" || sessionId.length === 0) return empty;
  if (opts.baked !== void 0 && !(0, import_node_fs4.existsSync)(metaPath(opts.workerDir, sessionId))) {
    const transcriptPath = asString(payload.transcript_path);
    writeMeta(opts.workerDir, {
      tmux_name: opts.baked.tmuxName,
      session_id: sessionId,
      cwd: opts.baked.cwd,
      harness: "codex",
      ...transcriptPath.length > 0 ? { transcript_path: transcriptPath } : {}
    });
  }
  if (!(0, import_node_fs4.existsSync)(metaPath(opts.workerDir, sessionId))) return empty;
  const hookEventName = asString(payload.hook_event_name);
  const event = EVENT_MAP[hookEventName];
  if (event === void 0) return empty;
  const ts = opts.now();
  const worker = buildEvent(event, ts, payload);
  appendEvent(eventsPath(opts.workerDir, sessionId), worker);
  return { stdout: "", appended: worker };
}
function buildEvent(event, ts, payload) {
  switch (event) {
    case "session_start": {
      const cwd = asString(payload.cwd);
      return cwd.length > 0 ? { event, ts, cwd } : { event, ts };
    }
    case "pre_tool_use": {
      const toolInput = payload.tool_input;
      return {
        event,
        ts,
        tool: asString(payload.tool_name),
        tool_input: typeof toolInput === "object" && toolInput !== null ? toolInput : {}
      };
    }
    case "post_tool_use":
      return { event, ts, tool: asString(payload.tool_name) };
    case "stop": {
      const stopHookActive = typeof payload.stop_hook_active === "boolean" ? payload.stop_hook_active : void 0;
      const tasks = backgroundTasks(payload.background_tasks);
      const crons = sessionCrons(payload.session_crons);
      return {
        event,
        ts,
        ...terminalEvidence(payload),
        ...stopHookActive === void 0 ? {} : { stop_hook_active: stopHookActive },
        ...tasks === void 0 ? {} : { background_tasks: tasks },
        ...crons === void 0 ? {} : { session_crons: crons }
      };
    }
    case "stop_failure": {
      const errorDetails = boundedString(payload.error_details);
      return {
        event,
        ts,
        ...terminalEvidence(payload),
        error: asString(payload.error),
        ...errorDetails === void 0 ? {} : { error_details: errorDetails }
      };
    }
    default:
      return { event, ts };
  }
}
function readStdin(timeoutMs = 5e3) {
  return new Promise((resolve) => {
    let data = "";
    let done = false;
    const finish = (value) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      resolve(value);
    };
    const timer = setTimeout(() => finish(data), timeoutMs);
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (chunk) => {
      data += chunk;
    });
    process.stdin.on("end", () => finish(data));
    process.stdin.on("error", () => finish(data));
  });
}
async function main() {
  const stdin = await readStdin();
  const args = process.argv.slice(2);
  let baked;
  let dir = workerDir();
  if (args.length >= 3) {
    const [tmuxName = "", cwd = "", bakedWorkerDir = ""] = args;
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
    baked
  });
  if (result.stdout.length > 0) {
    process.stdout.write(`${result.stdout}
`);
  }
  process.exit(0);
}
if (typeof require !== "undefined" && typeof module !== "undefined" && require.main === module) {
  void main();
}
// Annotate the CommonJS export names for ESM import in node:
0 && (module.exports = {
  MAX_EVENT_TEXT_LENGTH,
  runHook
});
