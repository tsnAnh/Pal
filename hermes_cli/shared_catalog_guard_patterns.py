from __future__ import annotations

from typing import NamedTuple

_MIN_ABBREVIATION = 2


class FlaggedVerb(NamedTuple):
    description: str
    flag: str | None = None
    exempt_flag: str | None = None


_REPLACE_SHARED = FlaggedVerb("overwrite a shared MCP definition for every bot", flag="--replace-shared")
_REMOVE_EVERYWHERE = FlaggedVerb("delete a shared MCP definition for every bot", flag="--everywhere")
_CATALOG_MIGRATE = FlaggedVerb(
    "move every bot's skills and MCP servers into the shared catalog, or roll that move back",
    exempt_flag="--dry-run")

HUMAN_REQUIRED_FLAGGED_VERBS: dict[tuple[str, str], FlaggedVerb] = {
    ("mcp", "add"): _REPLACE_SHARED,
    ("mcp", "save"): _REPLACE_SHARED,
    ("mcp", "remove"): _REMOVE_EVERYWHERE,
    ("mcp", "rm"): _REMOVE_EVERYWHERE,
    ("catalog", "migrate"): _CATALOG_MIGRATE,
}


def _is_flag(token: str, flag: str) -> bool:
    name = token.lower().partition("=")[0]
    return name == flag or (len(name) > _MIN_ABBREVIATION and name.startswith("--") and flag.startswith(name))


def flagged_verb_description(verb: tuple[str, str], later_args: list[str]) -> str | None:
    entry = HUMAN_REQUIRED_FLAGGED_VERBS.get(verb)
    if entry is None:
        return None
    if entry.flag is not None:
        return entry.description if any(_is_flag(token, entry.flag) for token in later_args) else None
    if entry.exempt_flag is not None and any(_is_flag(token, entry.exempt_flag) for token in later_args):
        return None
    return entry.description
