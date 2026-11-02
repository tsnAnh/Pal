from __future__ import annotations

import os
import re
from dataclasses import dataclass
from pathlib import Path

SKIP_DIRS = frozenset({
    ".git", ".github", ".hub", ".archive", ".curator_backups", ".locks", ".restore-backups",
    ".venv", "venv", "node_modules", "site-packages", "__pycache__",
})
SUPPORT_DIRS = frozenset({"references", "templates", "assets", "scripts"})
_NAME_LINE_RE = re.compile(r"^name:.*$", re.MULTILINE)


@dataclass(frozen=True)
class Found:
    key: str
    path: Path
    flat: bool
    link: bool


def discover_skills(root: Path) -> list[Found]:
    if not root.is_dir():
        return []
    found: list[Found] = []
    skill_dirs: set[Path] = set()
    flat: list[Path] = []
    for current, dirs, files in os.walk(root, followlinks=True):
        base = Path(current)
        has_skill = "SKILL.md" in files
        dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS and not (has_skill and d in SUPPORT_DIRS))
        if has_skill and base != root:
            skill_dirs.add(base)
            found.append(Found(base.relative_to(root).as_posix(), base, False, base.is_symlink()))
        flat.extend(base / f for f in sorted(files) if f.endswith(".md") and f not in ("SKILL.md", "DESCRIPTION.md"))
    for path in flat:
        rel = path.relative_to(root)
        if not any(part.startswith(".") for part in rel.parts) and not any(p in skill_dirs for p in path.parents):
            found.append(Found(rel.as_posix(), path, True, False))
    return found


def skill_name(item: Found) -> str:
    from tools.skill_usage import read_skill_name

    if item.flat:
        return read_skill_name(item.path, item.path.stem)
    return read_skill_name(item.path / "SKILL.md", item.path.name)


def rewrite_skill_name(skill_md: Path, new_name: str) -> None:
    lines = skill_md.read_text(encoding="utf-8-sig").split("\n")
    if lines[0].strip() != "---":
        return
    close = next((i for i, line in enumerate(lines[1:], 1) if line.strip() == "---"), None)
    if close is None:
        return
    block = "\n".join(lines[1:close])
    if not _NAME_LINE_RE.search(block):
        return
    block = _NAME_LINE_RE.sub(lambda _m: f"name: {new_name}", block, count=1)
    skill_md.write_text("\n".join([lines[0], block, *lines[close:]]), encoding="utf-8")
