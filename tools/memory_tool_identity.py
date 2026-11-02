from __future__ import annotations

import json
import logging
import re
from dataclasses import dataclass, replace
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any, Callable, Optional

from tools.memory_tool_store import FAILURE_CLASS
from tools.threat_patterns import first_threat_message
from utils import atomic_json_write, atomic_write_text

logger = logging.getLogger("tools.memory_tool")

IDENTITY_TARGET = "identity"
HISTORY_DIRNAME = "identity-history"
HISTORY_KEEP = 50
SOUL_FILENAME = "SOUL.md"
SECTION_MAX_CHARS = 4000
HEADING_MAX_CHARS = 80
DESCRIPTION_MAX_CHARS = 280
DISPLAY_NAME_MAX_CHARS = 64
MAX_OPERATIONS = 8
ROLE_HEADING = "Role"
SAVED_MESSAGE = "Saved. This takes effect in new chats; keep following it in this chat."

_SNAPSHOT_NAME_RE = re.compile(r"^(\d{8}T\d{12}Z)\.json$")
_SNAPSHOT_TIME_FORMAT = "%Y%m%dT%H%M%S%fZ"
_FENCE_RE = re.compile(r"^ {0,3}(`{3,}|~{3,})")
_HEADING_RE = re.compile(r"^ {0,3}(#{1,6})[ \t]+(\S.*?)(?:[ \t]+#+)?[ \t]*$")
_HEADING_ARG_RE = re.compile(r"^\s*(#{1,6})?\s*(.*?)\s*$", re.DOTALL)
_CONTROL_RE = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")


class IdentityError(ValueError):
    def __init__(self, message: str, failure_class: str = "invalid_args", **extra: Any) -> None:
        super().__init__(message)
        self.failure_class = failure_class
        self.extra = extra


@dataclass(frozen=True, slots=True)
class Identity:
    soul: Optional[str]
    description: str
    description_auto: bool
    display_name: str


@dataclass(frozen=True, slots=True)
class IdentityOp:
    action: str
    heading: str = ""
    content: str = ""


@dataclass(frozen=True, slots=True)
class Change:
    kind: str
    summary: str


@dataclass(frozen=True, slots=True)
class _Section:
    level: int
    title: str
    start: int
    end: int


_FIELD_GROUPS: dict[str, tuple[str, ...]] = {
    "soul": ("soul",),
    "description": ("description", "description_auto"),
    "display_name": ("display_name",),
}
_STALE_UNDO_MESSAGE = (
    "This identity was edited after that change, so undoing it would overwrite the newer edits. "
    "Nothing was changed.")


def soul_path(home: Path) -> Path:
    return Path(home) / SOUL_FILENAME


def history_dir(home: Path) -> Path:
    return Path(home) / HISTORY_DIRNAME


def denial_reason() -> Optional[str]:
    from agent.delegation_context import is_delegated_child_process_context, owned_kanban_task
    from tools.approval_context import _no_user_can_answer, _session_env
    from tools.skill_provenance import is_background_review

    checks: tuple[tuple[Callable[[], bool], str], ...] = (
        (is_background_review, "a background review"),
        (is_delegated_child_process_context, "a delegated subagent"),
        (lambda: bool(owned_kanban_task()) or _session_env("HERMES_SESSION_SOURCE") == "kanban", "a kanban worker"),
        (_no_user_can_answer, "a scheduled, webhook, API or single-query run"),
    )
    for is_active, label in checks:
        if is_active():
            return (f"Identity changes are only accepted from the user's own words in a live chat, and this is "
                    f"{label}. Nothing was changed. Do not retry; tell the user what they could ask for instead.")
    return None


def _fold(text: str) -> str:
    return " ".join(text.casefold().split())


def _scan(text: str) -> None:
    if message := first_threat_message(text):
        raise IdentityError(f"{message} Nothing was changed.", "scan_blocked")


def _clean_body(content: str, what: str) -> str:
    body = (content or "").replace("\r\n", "\n").replace("\r", "\n").lstrip("﻿").strip()
    if not body:
        raise IdentityError(f"{what} needs non-empty content.", "missing_content")
    if _CONTROL_RE.search(body):
        raise IdentityError(f"{what} contains control characters.")
    if len(body) > SECTION_MAX_CHARS:
        raise IdentityError(
            f"{what} is {len(body):,} chars; keep each section under {SECTION_MAX_CHARS:,}. "
            "Summarize it and retry. Nothing was changed.", "over_budget")
    _scan(body)
    return body


def _clean_line(text: str, what: str, limit: int) -> str:
    if _CONTROL_RE.search(text or ""):
        raise IdentityError(f"{what} contains control characters.")
    line = " ".join((text or "").split())
    if not line:
        raise IdentityError(f"{what} needs non-empty content.", "missing_content")
    if len(line) > limit:
        raise IdentityError(f"{what} is {len(line)} chars; keep it under {limit}. Nothing was changed.", "over_budget")
    _scan(line)
    return line


def _split_heading_arg(heading: str) -> tuple[int, str]:
    match = _HEADING_ARG_RE.match(heading or "")
    hashes, title = (match.group(1) or "", match.group(2)) if match else ("", "")
    return len(hashes), title


def _parse_sections(lines: list[str]) -> list[_Section]:
    heads: list[tuple[int, str, int]] = []
    fence: Optional[str] = None
    for index, line in enumerate(lines):
        if fenced := _FENCE_RE.match(line):
            char = fenced.group(1)[0]
            if fence is None:
                fence = char
            elif fence == char:
                fence = None
            continue
        if fence is None and (match := _HEADING_RE.match(line)):
            heads.append((len(match.group(1)), match.group(2).strip(), index))
    sections = []
    for position, (level, title, start) in enumerate(heads):
        end = next((s for lv, _t, s in heads[position + 1:] if lv <= level), len(lines))
        sections.append(_Section(level, title, start, end))
    return sections


def _titles(lines: list[str]) -> list[str]:
    return [section.title for section in _parse_sections(lines)]


def _find_section(lines: list[str], heading: str) -> Optional[_Section]:
    level, title = _split_heading_arg(heading)
    key = _fold(title)
    matches = [s for s in _parse_sections(lines) if _fold(s.title) == key and level in (0, s.level)]
    if len(matches) > 1:
        raise IdentityError(
            f"'{title}' matches {len(matches)} sections ({', '.join('#' * s.level + ' ' + s.title for s in matches)}). "
            "Retry with the heading prefixed by its # marks, for example '## Role'.", "ambiguous")
    return matches[0] if matches else None


def _clean_heading(heading: str) -> str:
    _level, title = _split_heading_arg(heading)
    title = _clean_line(title, "heading", HEADING_MAX_CHARS)
    if "<!--" in title or "-->" in title:
        raise IdentityError("heading must be plain text.")
    return title


def _reject_nested_headings(body: str, level: int) -> None:
    if any(s.level <= level for s in _parse_sections(body.split("\n"))):
        raise IdentityError(
            f"content may not contain headings at level {level} or above; use one call per section "
            f"or '{'#' * (level + 1)}' subheadings.")


def _first_line(text: str, limit: int = 90) -> str:
    line = next((ln.strip() for ln in text.splitlines() if ln.strip()), "")
    line = re.sub(r"^(?:[-*+]\s+|#{1,6}\s+|\d+[.)]\s+)", "", line)
    return line if len(line) <= limit else line[: limit - 1].rstrip() + "…"


def _lines_of(soul: Optional[str]) -> list[str]:
    return (soul or "").split("\n")


def _join(lines: list[str]) -> str:
    return "\n".join(lines).strip("\n") + "\n"


def _seed_soul() -> str:
    from hermes_cli.default_soul import DEFAULT_SOUL_MD
    return DEFAULT_SOUL_MD


def _with_soul(current: Identity, soul: str, change: Change) -> tuple[Identity, Change]:
    previous = current.soul or ""
    from agent.prompt_builder import CONTEXT_FILE_MAX_CHARS
    if len(soul) > CONTEXT_FILE_MAX_CHARS and len(soul) > len(previous):
        raise IdentityError(
            f"SOUL.md would reach {len(soul):,}/{CONTEXT_FILE_MAX_CHARS:,} chars. Remove or shorten a section "
            "first (one call can do both). Nothing was changed.", "over_budget",
            sections=_titles(_lines_of(current.soul)))
    return replace(current, soul=soul), change


def _missing_section(current: Identity, heading: str, hint: str) -> IdentityError:
    return IdentityError(
        f"No section '{heading}' in your SOUL. {hint}", "no_match", sections=_titles(_lines_of(current.soul)))


def _append_section(base: str, title: str, body: str) -> str:
    block = f"## {title}\n\n{body}\n"
    base = base.rstrip("\n")
    return f"{base}\n\n{block}" if base else block


def _replace_section(lines: list[str], section: _Section, body: str) -> str:
    return _join([*lines[: section.start + 1], "", *body.split("\n"), "", *lines[section.end:]])


def _add(current: Identity, op: IdentityOp) -> tuple[Identity, Change]:
    title = _clean_heading(op.heading)
    body = _clean_body(op.content, f"section '{title}'")
    _reject_nested_headings(body, 2)
    base = current.soul if current.soul is not None else _seed_soul()
    if _find_section(_lines_of(base), title) is not None:
        raise IdentityError(f"Section '{title}' already exists. Use action 'replace' to change it.", "ambiguous",
                            sections=_titles(_lines_of(base)))
    return _with_soul(current, _append_section(base, title, body),
                      Change("soul", f"Updated my {title.lower()}: {_first_line(body)}"))


def _replace(current: Identity, op: IdentityOp) -> tuple[Identity, Change]:
    title = _clean_heading(op.heading)
    lines = _lines_of(current.soul)
    section = _find_section(lines, title)
    if section is None:
        raise _missing_section(current, title, "Use action 'add' to create it.")
    body = _clean_body(op.content, f"section '{title}'")
    _reject_nested_headings(body, section.level)
    return _with_soul(current, _replace_section(lines, section, body),
                      Change("soul", f"Updated my {section.title.lower()}: {_first_line(body)}"))


def _set_section(current: Identity, op: IdentityOp) -> tuple[Identity, Change]:
    title = _clean_heading(op.heading)
    section = _find_section(_lines_of(current.soul), title)
    return (_replace if section is not None else _add)(current, op)


def _remove(current: Identity, op: IdentityOp) -> tuple[Identity, Change]:
    title = _clean_heading(op.heading)
    lines = _lines_of(current.soul)
    section = _find_section(lines, title)
    if section is None:
        raise _missing_section(current, title, "Nothing to remove.")
    head = lines[: section.start]
    while head and not head[-1].strip():
        head.pop()
    tail = lines[section.end:]
    joined = _join([*head, *([""] if head and tail else []), *tail]) if head or tail else ""
    return _with_soul(current, joined, Change("soul", f"Removed my {section.title.lower()} section"))


def _set_description(current: Identity, op: IdentityOp) -> tuple[Identity, Change]:
    text = _clean_line(op.content, "description", DESCRIPTION_MAX_CHARS)
    return (replace(current, description=text, description_auto=False),
            Change("description", f"Updated my description: {_first_line(text)}"))


def _set_display_name(current: Identity, op: IdentityOp) -> tuple[Identity, Change]:
    name = _clean_line(op.content, "display name", DISPLAY_NAME_MAX_CHARS)
    return replace(current, display_name=name), Change("display_name", f"Renamed myself to {name}")


_REDUCERS: dict[str, Callable[[Identity, IdentityOp], tuple[Identity, Change]]] = {
    "add": _add, "replace": _replace, "remove": _remove, "set_section": _set_section,
    "set_description": _set_description, "set_display_name": _set_display_name,
}
UNDO_ACTION = "undo"
MODEL_ACTIONS = frozenset({"add", "replace", "remove", "set_description", "set_display_name", UNDO_ACTION})


def reduce_ops(current: Identity, ops: list[IdentityOp]) -> tuple[Identity, list[Change]]:
    changes: list[Change] = []
    for op in ops:
        current, change = _REDUCERS[op.action](current, op)
        changes.append(change)
    return current, changes


def _read_soul(home: Path) -> Optional[str]:
    path = soul_path(home)
    if not path.exists():
        return None
    try:
        return path.read_text(encoding="utf-8-sig").replace("\r\n", "\n")
    except (OSError, UnicodeDecodeError) as exc:
        raise IdentityError(
            "SOUL.md exists but could not be read right now; nothing was changed. Retry in a moment.",
            "read_failed") from exc


def read_identity(home: Path) -> Identity:
    from hermes_cli.profiles import read_profile_meta
    meta = read_profile_meta(Path(home))
    return Identity(_read_soul(home), meta["description"], bool(meta["description_auto"]), meta["display_name"])


def _write_soul(home: Path, soul: Optional[str]) -> None:
    path = soul_path(home)
    if soul is None:
        path.unlink(missing_ok=True)
        return
    atomic_write_text(path, soul, preserve_mode=True, create_mode=0o600)


def _write_meta(home: Path, before: Identity, after: Identity) -> None:
    fields: dict[str, Any] = {}
    if after.description != before.description:
        fields["description"] = after.description
    if after.description_auto != before.description_auto or "description" in fields:
        fields["description_auto"] = after.description_auto
    if after.display_name != before.display_name:
        fields["display_name"] = after.display_name
    if fields:
        from hermes_cli.profiles import write_profile_meta
        write_profile_meta(Path(home), **fields)


def _write_identity(home: Path, before: Identity, after: Identity) -> None:
    soul_changed = after.soul != before.soul
    if soul_changed:
        _write_soul(home, after.soul)
    try:
        _write_meta(home, before, after)
    except Exception:
        if soul_changed:
            _write_soul(home, before.soul)
        raise


def _snapshot_files(directory: Path) -> list[Path]:
    if not directory.is_dir():
        return []
    return sorted((p for p in directory.iterdir() if _SNAPSHOT_NAME_RE.match(p.name)), key=lambda p: p.name)


def _next_snapshot_id(directory: Path) -> str:
    now = datetime.now(UTC)
    files = _snapshot_files(directory)
    if files:
        last = datetime.strptime(files[-1].stem, _SNAPSHOT_TIME_FORMAT).replace(tzinfo=UTC)
        if last >= now:
            now = last + timedelta(microseconds=1)
    return now.strftime(_SNAPSHOT_TIME_FORMAT)


def _identity_fields(identity: Identity) -> dict[str, Any]:
    return {"soul": identity.soul, "description": identity.description,
            "description_auto": identity.description_auto, "display_name": identity.display_name}


def _save_snapshot(home: Path, before: Identity, after: Identity, changes: list[Change]) -> str:
    directory = history_dir(home)
    change_id = _next_snapshot_id(directory)
    atomic_json_write(directory / f"{change_id}.json", {
        "version": 1, "id": change_id, "created_at": datetime.now(UTC).isoformat(),
        "kind": _kind_of(changes), "summary": _summary_of(changes),
        **_identity_fields(before), "after": _identity_fields(after),
    }, mode=0o600)
    for stale in _snapshot_files(directory)[:-HISTORY_KEEP]:
        stale.unlink(missing_ok=True)
    return change_id


def _valid_fields(data: Any) -> bool:
    return (isinstance(data, dict) and (data.get("soul") is None or isinstance(data["soul"], str))
            and isinstance(data.get("description"), str) and isinstance(data.get("description_auto"), bool)
            and isinstance(data.get("display_name"), str))


def _load_snapshot(path: Path) -> Optional[dict[str, Any]]:
    try:
        data = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError):
        return None
    valid = (_valid_fields(data) and data.get("version") == 1 and isinstance(data.get("summary"), str)
             and _valid_fields(data.get("after")))
    return {**data, "id": path.stem} if valid else None


def _newest_snapshot(home: Path) -> Optional[tuple[Path, dict[str, Any]]]:
    for path in reversed(_snapshot_files(history_dir(home))):
        if (data := _load_snapshot(path)) is not None:
            return path, data
    return None


def history_depth(home: Path) -> int:
    return sum(1 for p in _snapshot_files(history_dir(home)) if _load_snapshot(p) is not None)


def _kind_of(changes: list[Change]) -> str:
    kinds = {c.kind for c in changes}
    return kinds.pop() if len(kinds) == 1 else "multiple"


def _summary_of(changes: list[Change]) -> str:
    return "; ".join(dict.fromkeys(c.summary for c in changes))[:240]


def _locked(home: Path):
    from hermes_constants import mkdir_under_hermes_home
    from tools.skill_usage import skill_file_lock

    directory = history_dir(home)
    mkdir_under_hermes_home(directory)
    return skill_file_lock(directory / ".lock")


def _success(home: Path, after: Identity, kind: str, summary: str, change_id: Optional[str], *,
             message: str = SAVED_MESSAGE) -> dict[str, Any]:
    from agent.prompt_builder import CONTEXT_FILE_MAX_CHARS
    result: dict[str, Any] = {
        "success": True, "target": IDENTITY_TARGET, "message": message, "summary": summary,
        "sections": _titles(_lines_of(after.soul)),
        "usage": f"{SOUL_FILENAME} {len(after.soul or ''):,}/{CONTEXT_FILE_MAX_CHARS:,} chars",
        "identity_change": {
            "kind": kind, "summary": summary, "undo_available": history_depth(home) > 0, "change_id": change_id},
    }
    return result


def apply_identity_ops(home: Path, ops: list[IdentityOp]) -> dict[str, Any]:
    home = Path(home)
    with _locked(home):
        before = read_identity(home)
        after, changes = reduce_ops(before, ops)
        if after == before:
            return {"success": True, "target": IDENTITY_TARGET, "changed": False,
                    "message": "Already up to date; nothing changed.",
                    "sections": _titles(_lines_of(before.soul))}
        change_id = _save_snapshot(home, before, after, changes)
        try:
            _write_identity(home, before, after)
        except Exception:
            history_dir(home).joinpath(f"{change_id}.json").unlink(missing_ok=True)
            raise
    return _success(home, after, _kind_of(changes), _summary_of(changes), change_id)


def _touched_groups(snapshot: dict[str, Any]) -> list[str]:
    return [group for group, keys in _FIELD_GROUPS.items()
            if any(snapshot[key] != snapshot["after"][key] for key in keys)]


def undo_identity(home: Path, change_id: Optional[str] = None) -> dict[str, Any]:
    home = Path(home)
    with _locked(home):
        newest = _newest_snapshot(home)
        if newest is None:
            raise IdentityError("There is no earlier identity version to restore.", "no_match")
        path, snapshot = newest
        if change_id and snapshot["id"] != change_id:
            raise IdentityError(
                "A newer identity change exists, so this one can no longer be undone on its own. "
                "Nothing was changed.", "stale_entry")
        current = _identity_fields(read_identity(home))
        keys = [key for group in _touched_groups(snapshot) for key in _FIELD_GROUPS[group]]
        if any(current[key] != snapshot["after"][key] for key in keys):
            raise IdentityError(_STALE_UNDO_MESSAGE, "stale_entry")
        before = Identity(**current)
        restored = Identity(**{**current, **{key: snapshot[key] for key in keys}})
        _write_identity(home, before, restored)
        path.unlink(missing_ok=True)
    summary = f"Reverted my last identity change: {snapshot['summary']}"[:240]
    return _success(home, restored, "undo", summary, None, message="Restored the previous version.")


def replace_soul(home: Path, soul: str) -> None:
    home = Path(home)
    with _locked(home):
        _write_soul(home, soul)


def apply_onboarding_purpose(home: Path, purpose_text: str) -> dict[str, Any]:
    purpose = _clean_body(purpose_text, "purpose")
    one_line = " ".join(purpose.split())
    if len(one_line) > DESCRIPTION_MAX_CHARS:
        one_line = one_line[: DESCRIPTION_MAX_CHARS - 1].rsplit(" ", 1)[0].rstrip(" ,;:.") + "…"
    return apply_identity_ops(Path(home), [
        IdentityOp("set_section", ROLE_HEADING, purpose), IdentityOp("set_description", content=one_line)])


def parse_ops(action: Any, heading: Any, content: Any, operations: Any) -> list[IdentityOp]:
    raw = operations if isinstance(operations, list) and operations else [
        {"action": action, "heading": heading, "content": content}]
    if len(raw) > MAX_OPERATIONS:
        raise IdentityError(f"At most {MAX_OPERATIONS} operations per call.")
    ops = []
    for item in raw:
        if not isinstance(item, dict):
            raise IdentityError("operations must be a list of {action, heading?, content?} objects.")
        name = str(item.get("action") or "")
        if name not in MODEL_ACTIONS:
            raise IdentityError(f"Unknown identity action '{name}'. Use: {', '.join(sorted(MODEL_ACTIONS))}.")
        text = item.get("content") or item.get("new_text") or ""
        ops.append(IdentityOp(name, str(item.get("heading") or ""), text if isinstance(text, str) else ""))
    if any(op.action == UNDO_ACTION for op in ops) and len(ops) > 1:
        raise IdentityError("'undo' must be the only operation in its call.")
    return ops


def _gate_message(ops: list[IdentityOp], preview: str) -> Optional[str]:
    try:
        from tools import write_approval as wa
    except ImportError:
        return None
    detail = "\n".join(f"- {op.action} {op.heading}: {op.content}".rstrip(": ") for op in ops)
    decision = wa.evaluate_gate(wa.MEMORY, inline_summary=f"change my identity: {preview}", inline_detail=detail)
    if decision.allow:
        return None
    FAILURE_CLASS.set("gate_refused")
    if decision.blocked:
        return decision.message
    return ("Identity changes cannot wait in the approval queue. Ask the user to confirm in this chat, "
            "then retry. Nothing was changed.")


def _error_result(error: IdentityError) -> tuple[str, str]:
    from tools.registry import tool_error
    FAILURE_CLASS.set(error.failure_class)
    return "rejected", tool_error(str(error), success=False, target=IDENTITY_TARGET, **error.extra)


def identity_tool(*, action: Any, heading: Any, content: Any, operations: Any, home: Optional[Path]) -> tuple[str, str]:
    from hermes_constants import get_hermes_home
    from tools.registry import tool_error

    if (reason := denial_reason()) is not None:
        FAILURE_CLASS.set("gate_refused")
        return "rejected", tool_error(reason, success=False, target=IDENTITY_TARGET)
    target_home = Path(home) if home is not None else get_hermes_home()
    try:
        ops = parse_ops(action, heading, content, operations)
        is_undo = ops[0].action == UNDO_ACTION
        if is_undo:
            if _newest_snapshot(target_home) is None:
                raise IdentityError("There is no earlier identity version to restore.", "no_match")
            preview = "undo my last identity change"
        else:
            _, changes = reduce_ops(read_identity(target_home), ops)
            preview = _summary_of(changes)
        if (blocked := _gate_message(ops, preview)) is not None:
            return "rejected", tool_error(blocked, success=False, target=IDENTITY_TARGET)
        result = undo_identity(target_home) if is_undo else apply_identity_ops(target_home, ops)
    except IdentityError as error:
        return _error_result(error)
    except OSError as exc:
        logger.warning("Identity write failed for %s: %s", target_home, exc)
        FAILURE_CLASS.set("other")
        return "failed", tool_error("Could not save the identity change right now; nothing was changed.",
                                    success=False, target=IDENTITY_TARGET)
    return "success", json.dumps(result, ensure_ascii=False)
