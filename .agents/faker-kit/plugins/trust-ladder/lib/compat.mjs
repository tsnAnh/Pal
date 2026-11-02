import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const COMPAT_START = "<!-- faker-kit:compat:start -->";
export const COMPAT_END = "<!-- faker-kit:compat:end -->";
const COMPAT_FILE = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "references", "compat.md");

export function compatBlock() {
  const text = fs.readFileSync(COMPAT_FILE, "utf8");
  const start = text.indexOf(COMPAT_START);
  const end = text.indexOf(COMPAT_END);
  if (start === -1 || end === -1) throw new Error(`${COMPAT_FILE} is missing its compat markers`);
  return text.slice(start, end + COMPAT_END.length);
}

function candidateDirs(cwd) {
  const dirs = [];
  let dir = path.resolve(cwd);
  for (;;) {
    dirs.push(dir);
    if (fs.existsSync(path.join(dir, ".git"))) break;
    const parent = path.dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  return dirs;
}

export function projectHasCompat(cwd) {
  for (const dir of candidateDirs(cwd)) {
    for (const name of ["AGENTS.md", "CLAUDE.md"]) {
      const file = path.join(dir, name);
      if (fs.existsSync(file) && fs.readFileSync(file, "utf8").includes(COMPAT_START)) return true;
    }
  }
  return false;
}
