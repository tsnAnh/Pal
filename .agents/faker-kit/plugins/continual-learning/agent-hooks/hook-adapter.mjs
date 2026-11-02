#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const USAGE = `Usage: node agent-hooks/hook-adapter.mjs <PostToolUse|Stop|SubagentStop> < hook-input.json

Runs this plugin's upstream hooks (hooks/hooks.json, in the upstream hook format) from
a Claude Code hook. Translates the agent's hook input into the upstream format,
runs each matching upstream command, and turns an upstream "followup_message" into a
{"decision": "block", "reason": ...} reply, which makes the agent continue with it.

  PostToolUse   runs afterFileEdit hooks after Edit, Write, MultiEdit, or NotebookEdit
  Stop          runs afterAgentResponse hooks, then stop hooks
  SubagentStop  runs subagentStop hooks whose matcher fits the subagent's name

Generated into each vendored plugin by scripts/sync-upstream.mjs. Always exits 0 so a
failing upstream hook never blocks the agent; failures go to stderr.
`;

export const UPSTREAM_EVENTS = {
  PostToolUse: ["afterFileEdit"],
  Stop: ["afterAgentResponse", "stop"],
  SubagentStop: ["subagentStop"],
};
export const EDIT_TOOL_MATCHER = "Edit|Write|MultiEdit|NotebookEdit";
const FOLLOWUP_EVENTS = new Set(["stop", "subagentStop"]);
const DEFAULT_LOOP_LIMIT = 5;
const DEFAULT_TIMEOUT_SECONDS = 50;

export function editedFile(toolInput) {
  if (!toolInput || typeof toolInput !== "object") return "";
  for (const key of ["file_path", "notebook_path", "path"]) {
    if (typeof toolInput[key] === "string") return toolInput[key];
  }
  return "";
}

export function subagentName(agentType) {
  return String(agentType ?? "").split(":").pop();
}

export function upstreamInput(upstreamEvent, input, { projectDir, loopCount }) {
  const common = {
    conversation_id: input.session_id,
    model: input.model,
    hook_event_name: upstreamEvent,
    workspace_roots: [projectDir],
    transcript_path: input.transcript_path ?? null,
  };
  if (upstreamEvent === "afterFileEdit") {
    const file = editedFile(input.tool_input);
    return { ...common, file_path: file && !path.isAbsolute(file) ? path.join(projectDir, file) : file, edits: [] };
  }
  if (upstreamEvent === "afterAgentResponse") return { ...common, text: input.last_assistant_message ?? "" };
  if (upstreamEvent === "stop") return { ...common, status: "completed", loop_count: loopCount };
  if (upstreamEvent === "subagentStop") {
    return { ...common, subagent_type: subagentName(input.agent_type), status: "completed", summary: input.last_assistant_message ?? "", loop_count: loopCount };
  }
  return common;
}

function matches(entry, upstreamEvent, input) {
  if (!entry.matcher) return true;
  const re = new RegExp(entry.matcher);
  if (upstreamEvent === "subagentStop") return re.test(subagentName(input.agent_type));
  if (upstreamEvent === "afterFileEdit") return re.test(editedFile(input.tool_input));
  return true;
}

function lastJsonObject(stdout) {
  const text = String(stdout ?? "").trim();
  for (const line of [text, ...text.split("\n").reverse()]) {
    try {
      const value = JSON.parse(line);
      if (value && typeof value === "object") return value;
    } catch {}
  }
  return null;
}

function runCommand(command, stdinText, env, cwd, timeoutSeconds) {
  const result = spawnSync("bash", ["-c", command], { input: stdinText, env, cwd, encoding: "utf8", timeout: timeoutSeconds * 1000 });
  return { status: result.status, stdout: result.stdout ?? "", stderr: `${result.stderr ?? ""}${result.error ? String(result.error) : ""}` };
}

function loopFile(dataDir) {
  return path.join(dataDir, "hook-loops.json");
}

function readLoops(dataDir) {
  try {
    return JSON.parse(fs.readFileSync(loopFile(dataDir), "utf8"));
  } catch {
    return {};
  }
}

function writeLoops(dataDir, loops) {
  try {
    fs.mkdirSync(dataDir, { recursive: true });
    fs.writeFileSync(loopFile(dataDir), JSON.stringify(loops));
  } catch {}
}

export function runAdapter(event, input, { pluginRoot, projectDir, dataDir, env = process.env, run = runCommand }) {
  const upstreamEvents = UPSTREAM_EVENTS[event];
  if (!upstreamEvents) throw new Error(`unsupported event "${event}"; expected ${Object.keys(UPSTREAM_EVENTS).join(", ")}`);
  if (event === "PostToolUse" && !new RegExp(`^(?:${EDIT_TOOL_MATCHER})$`).test(input.tool_name ?? "")) return { output: null, errors: [] };
  const config = JSON.parse(fs.readFileSync(path.join(pluginRoot, "hooks", "hooks.json"), "utf8"));
  const loopKey = [input.session_id, event, input.agent_id].filter(Boolean).join(":");
  const loops = readLoops(dataDir);
  const loopCount = input.stop_hook_active ? (loops[loopKey] ?? 0) : 0;
  const upstreamEnv = { ...env, CLAUDE_PLUGIN_ROOT: pluginRoot, CLAUDE_PROJECT_DIR: projectDir };
  const followups = [];
  const errors = [];
  for (const upstreamEvent of upstreamEvents) {
    for (const entry of config.hooks?.[upstreamEvent] ?? []) {
      if (!matches(entry, upstreamEvent, input)) continue;
      const stdinText = JSON.stringify(upstreamInput(upstreamEvent, input, { projectDir, loopCount }));
      const result = run(entry.command, stdinText, upstreamEnv, projectDir, entry.timeout ?? DEFAULT_TIMEOUT_SECONDS);
      if (result.status !== 0) {
        errors.push(`${upstreamEvent} hook "${entry.command}" exited ${result.status}: ${result.stderr.trim().split("\n").slice(-3).join(" ")}`);
        continue;
      }
      const reply = lastJsonObject(result.stdout);
      const limit = entry.loop_limit === null ? Infinity : (entry.loop_limit ?? DEFAULT_LOOP_LIMIT);
      if (FOLLOWUP_EVENTS.has(upstreamEvent) && typeof reply?.followup_message === "string" && reply.followup_message && loopCount < limit) {
        followups.push(reply.followup_message);
      }
    }
  }
  if (event !== "PostToolUse") {
    loops[loopKey] = followups.length > 0 ? loopCount + 1 : 0;
    if (!loops[loopKey]) delete loops[loopKey];
    writeLoops(dataDir, loops);
  }
  const output = followups.length > 0 ? { decision: "block", reason: followups.join("\n\n") } : null;
  return { output, errors };
}

function main() {
  const event = process.argv[2];
  if (!event || event === "-h" || event === "--help") {
    process.stdout.write(USAGE);
    return;
  }
  try {
    const input = JSON.parse(fs.readFileSync(0, "utf8") || "{}");
    const pluginRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
    const projectDir = process.env.CLAUDE_PROJECT_DIR || input.cwd || process.cwd();
    const dataDir = process.env.CLAUDE_PLUGIN_DATA || path.join(os.tmpdir(), `faker-kit-hooks-${path.basename(pluginRoot)}`);
    const { output, errors } = runAdapter(event, input, { pluginRoot, projectDir, dataDir });
    for (const error of errors) process.stderr.write(`hook-adapter: ${error}\n`);
    if (output) process.stdout.write(`${JSON.stringify(output)}\n`);
  } catch (error) {
    process.stderr.write(`hook-adapter: ${error.message}\n`);
  }
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) main();
