#!/usr/bin/env node
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { compatBlock, projectHasCompat } from "../lib/compat.mjs";
import { nextActiveModes, reminderText } from "../lib/modes.mjs";

const STATE_TTL_MS = 7 * 24 * 60 * 60 * 1000;

function stateDir() {
  const base = process.env.CLAUDE_PLUGIN_DATA || path.join(os.tmpdir(), "faker-kit");
  return path.join(base, "modes");
}

function stateFile(sessionId) {
  return path.join(stateDir(), `${String(sessionId || "default").replace(/[^A-Za-z0-9_.-]/g, "_")}.json`);
}

function loadModes(sessionId) {
  try {
    return new Set(JSON.parse(fs.readFileSync(stateFile(sessionId), "utf8")).active ?? []);
  } catch {
    return new Set();
  }
}

function saveModes(sessionId, active) {
  fs.mkdirSync(stateDir(), { recursive: true });
  fs.writeFileSync(stateFile(sessionId), `${JSON.stringify({ active: [...active] })}\n`);
}

function pruneOldState() {
  const dir = stateDir();
  if (!fs.existsSync(dir)) return;
  const cutoff = Date.now() - STATE_TTL_MS;
  for (const name of fs.readdirSync(dir)) {
    const file = path.join(dir, name);
    if (fs.statSync(file).mtimeMs < cutoff) fs.rmSync(file, { force: true });
  }
}

function emit(hookEventName, additionalContext) {
  if (!additionalContext) return;
  process.stdout.write(`${JSON.stringify({ hookSpecificOutput: { hookEventName, additionalContext } })}\n`);
}

export function handle(event, input) {
  const cwd = input.cwd || process.cwd();
  if (event === "session-start") {
    pruneOldState();
    return { hookEventName: "SessionStart", context: projectHasCompat(cwd) ? null : compatBlock() };
  }
  if (event === "user-prompt-submit") {
    const before = loadModes(input.session_id);
    const after = nextActiveModes(input.prompt ?? "", before);
    saveModes(input.session_id, after);
    const enteredNow = [...after].some((skill) => !before.has(skill));
    return { hookEventName: "UserPromptSubmit", context: enteredNow ? null : reminderText(after) };
  }
  throw new Error(`unknown event "${event}"; expected session-start or user-prompt-submit`);
}

async function main() {
  const event = process.argv[2];
  let raw = "";
  for await (const chunk of process.stdin) raw += chunk;
  const input = raw.trim() ? JSON.parse(raw) : {};
  const { hookEventName, context } = handle(event, input);
  emit(hookEventName, context);
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  main().catch((error) => {
    process.stderr.write(`faker-kit hook: ${error.message}\n`);
    process.exit(1);
  });
}
