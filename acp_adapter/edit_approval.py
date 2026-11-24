"""Edit proposals shown to an ACP client as the diff of a ``write_file`` / ``patch`` call."""

from __future__ import annotations

import logging
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class EditProposal:
    """A proposed single-file edit that can be shown to an ACP client."""

    tool_name: str
    path: str
    old_text: str | None
    new_text: str
    arguments: dict[str, Any]
    # Every file the edit will actually touch. ``path`` may be a comma-joined
    # display string for multi-file V4A patches; ``paths`` is the authoritative
    # set. Empty means "``path`` alone".
    paths: tuple[str, ...] = ()


# ``\s*`` after the stars as in tools/patch_parser.py: a header the parser applies must match here too.
_V4A_FILE_RE = re.compile(r'^\*\*\*\s*(?:Update|Add|Delete)\s+File:\s*(.+)$', re.MULTILINE)
_V4A_MOVE_RE = re.compile(r'^\*\*\*\s*Move\s+File:\s*(.+?)\s*->\s*(.+)$', re.MULTILINE)


def _read_text_if_exists(path: str) -> str | None:
    p = Path(path).expanduser()
    if p.is_file():
        return p.read_text(encoding="utf-8-sig", errors="replace")
    if p.exists():
        raise OSError(f"Cannot edit non-file path: {path}")
    return None


def _required_path(arguments: dict[str, Any]) -> str:
    path = str(arguments.get("path") or "")
    if not path:
        raise ValueError("path required")
    from tools.file_tools_paths import _resolve_path_for_task
    return str(_resolve_path_for_task(path))


def _proposal_for_write_file(arguments: dict[str, Any]) -> EditProposal:
    path = _required_path(arguments)
    content = arguments.get("content")
    if content is None:
        raise ValueError("content required")
    return EditProposal("write_file", path, _read_text_if_exists(path), str(content), dict(arguments))


def _proposal_for_patch_replace(arguments: dict[str, Any]) -> EditProposal:
    path = _required_path(arguments)
    old_string, new_string = arguments.get("old_string"), arguments.get("new_string")
    if old_string is None or new_string is None:
        raise ValueError("old_string and new_string required")
    old_text = _read_text_if_exists(path)
    if old_text is None:
        raise ValueError(f"Failed to read file: {path}")

    from tools.fuzzy_match import fuzzy_find_and_replace

    new_text, match_count, _strategy, error = fuzzy_find_and_replace(
        old_text, str(old_string), str(new_string), bool(arguments.get("replace_all", False)))
    if error or match_count == 0:
        raise ValueError(error or f"Could not find match for old_string in {path}")
    return EditProposal("patch", path, old_text, new_text, dict(arguments))


def _extract_v4a_patch_paths(patch_body: str) -> list[str]:
    paths = [m.group(1).strip() for m in _V4A_FILE_RE.finditer(patch_body)]
    for match in _V4A_MOVE_RE.finditer(patch_body):
        paths.extend(match.group(i).strip() for i in (1, 2))
    return [p for p in paths if p]


def _proposal_for_patch_v4a(arguments: dict[str, Any]) -> EditProposal:
    patch_body = arguments.get("patch")
    if not isinstance(patch_body, str) or not patch_body:
        raise ValueError("patch content required")
    paths = [_required_path({'path': path}) for path in _extract_v4a_patch_paths(patch_body)]
    if not paths:
        raise ValueError("no file paths found in V4A patch")
    single = len(paths) == 1
    # ACP only supports a single diff payload: surface the exact V4A patch as new_text so
    # patch-mode calls are permissioned and denied patches cannot mutate.
    return EditProposal(
        "patch", paths[0] if single else ", ".join(paths),
        _read_text_if_exists(paths[0]) if single else None, patch_body, dict(arguments),
        tuple(paths),
    )


# (tool_name, patch mode or None) -> proposal builder.
_PROPOSAL_BUILDERS = {
    ("write_file", None): _proposal_for_write_file, ("patch", "replace"): _proposal_for_patch_replace,
    ("patch", "patch"): _proposal_for_patch_v4a,
}


def build_edit_proposal(tool_name: str, arguments: dict[str, Any]) -> EditProposal | None:
    """Return an edit proposal for supported file mutation calls."""
    mode = arguments.get("mode", "replace") if tool_name == "patch" else None
    builder = _PROPOSAL_BUILDERS.get((tool_name, mode))
    return builder(arguments) if builder else None
