from __future__ import annotations

import itertools
import os
import re
from typing import NamedTuple

from hermes_cli.shared_catalog_guard_patterns import is_flag


class _GrantBinding(NamedTuple):
    action: str
    positional: bool = False
    option: str | None = None
    value_options: frozenset = frozenset()
    open_ended_options: frozenset = frozenset()
    exact_switches: frozenset = frozenset()


_MCP_VALUE_OPTIONS = frozenset({"--url", "--command", "--auth", "--preset", "--connect-timeout"})
_MCP_OPEN_ENDED_OPTIONS = frozenset({"--args", "--env"})
_MCP_REPLACE_BINDING = _GrantBinding(
    "mcp_replace_shared", positional=True, value_options=_MCP_VALUE_OPTIONS, open_ended_options=_MCP_OPEN_ENDED_OPTIONS)
_MCP_REMOVE_BINDING = _GrantBinding("mcp_remove_everywhere", positional=True)
GRANT_BINDINGS: dict[tuple[str, str], _GrantBinding] = {
    ("bot", "create"): _GrantBinding("create", positional=True, value_options=frozenset({"--display-name", "--description"})),
    ("profile", "create"): _GrantBinding(
        "create", positional=True, value_options=frozenset({"--clone-from", "--description"}),
        exact_switches=frozenset({"--clone"})),
    ("profile", "import"): _GrantBinding("import", option="--name"),
    ("profile", "install"): _GrantBinding("install", option="--name"),
    ("profile", "delete"): _GrantBinding("delete", positional=True),
    ("mcp", "add"): _MCP_REPLACE_BINDING,
    ("mcp", "save"): _MCP_REPLACE_BINDING,
    ("mcp", "remove"): _MCP_REMOVE_BINDING,
    ("mcp", "rm"): _MCP_REMOVE_BINDING,
    ("catalog", "migrate"): _GrantBinding("catalog_migrate"),
}
_PYTHON_API_ACTIONS = {
    "create_profile": "create",
    "delete_profile": "delete",
    "import_profile": "import",
    "install_profile": "install",
    "install_distribution": "install",
    "save_server": "mcp_replace_shared",
    "_save_mcp_server": "mcp_replace_shared",
    "replace_servers": "mcp_replace_shared",
    "_replace_mcp_servers": "mcp_replace_shared",
    "remove_server": "mcp_remove_everywhere",
    "_remove_mcp_server": "mcp_remove_everywhere",
}
_PROFILE_SELECTOR_FLAGS = frozenset({"-p", "--profile"})
_STATIC_PROFILE_NAME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]*")


def _static_name(token: str) -> str | None:
    return token if _STATIC_PROFILE_NAME_RE.fullmatch(token) else None


def bound_name(binding: _GrantBinding, later_args: list[str]) -> str | None:
    name, index = None, 0
    while index < len(later_args):
        token = later_args[index]
        index += 1
        if not token.startswith("-") or token == "-":
            if binding.positional:
                return _static_name(token)
            continue
        if token in _PROFILE_SELECTOR_FLAGS:
            index += 1
            continue
        if token.lower() in binding.exact_switches:
            continue
        inline_value = token.partition("=")[2] if "=" in token else None
        if binding.option is not None and is_flag(token, binding.option):
            value = inline_value if inline_value is not None else (later_args[index] if index < len(later_args) else "")
            name = _static_name(value)
            index += inline_value is None
        elif binding.positional and any(is_flag(token, option) for option in binding.open_ended_options):
            return None
        elif inline_value is None and any(is_flag(token, option) for option in binding.value_options):
            index += 1
    return name


def _python_api_scope(text: str) -> set[tuple[str, str | None]]:
    from tools import approval_detection as detection
    scope = set()
    for match in detection._HUMAN_REQUIRED_PYTHON_API.finditer(text):
        action = _PYTHON_API_ACTIONS.get(re.search(r"[A-Za-z_]\w*", match.group(0)).group(0))
        if action:
            scope.add((action, None))
    return scope


def _command_grant_scope(command: str) -> set[tuple[str, str | None]]:
    from tools import approval_detection as detection
    if detection._command_parser_limit_exceeded(command):
        return set()
    command, python_bodies = detection._split_heredocs(command)
    scope = set()
    for body in python_bodies:
        scope |= _code_grant_scope(body)
    launches_python = False
    for argv in detection._iter_command_argvs(command):
        hit = detection._human_required_hit(argv)
        if hit and hit[1]:
            scope.add(hit[1:])
        launches_python = launches_python or (
            os.path.basename(argv[0]).lower() not in detection._TEXT_ONLY_COMMANDS
            and detection._launches_python(argv))
    if launches_python and "hermes_cli" in command:
        scope |= _python_api_scope(command)
    return scope


def _code_grant_scope(code: str) -> set[tuple[str, str | None]]:
    from tools import approval_detection as detection
    if detection._command_parser_limit_exceeded(code):
        return set()
    scope = _python_api_scope(code) if "hermes_cli" in code else set()
    for candidate in itertools.islice(detection._code_command_candidates(code), detection._MAX_CODE_LITERALS):
        scope |= _command_grant_scope(candidate)
    return scope


def human_required_grant_scope(text: str, *, code: bool = False) -> frozenset[tuple[str, str | None]]:
    return frozenset(_code_grant_scope(text) if code else _command_grant_scope(text))
