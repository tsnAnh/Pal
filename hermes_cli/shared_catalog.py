from __future__ import annotations

import copy
import logging
import re
import threading
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Callable, Iterator, TypeVar
from urllib.parse import urlsplit

import hermes_yaml as yaml
from hermes_cli.profile_admin_guard import require_profile_admin_grant
from hermes_constants import CATALOG_MIGRATED_MARKER, get_shared_catalog_dir, get_shared_root

logger = logging.getLogger(__name__)

T = TypeVar("T")

MCP_DEFINITIONS_FILE = "mcp_servers.yaml"
CATALOG_LOCK_FILE = "catalog.lock"
OPT_OUT_APPLIED_FILE = ".no-bundled-skills.applied"
NO_BUNDLED_SKILLS_MARKER = ".no-bundled-skills"
TRANSPORT_KEYS = ("command", "url")
BOT_FLAG_KEYS = ("enabled", "disabled")
_SECRET_NAME_RE = re.compile(
    r"token|secret|key|passw|auth|credential|bearer|cookie|signature|(?:^|[-_])pat(?:$|[-_])", re.IGNORECASE)
_TOKEN_PREFIX_RE = re.compile(r"^(?:ghp_|gho_|ghu_|ghs_|ghr_|github_pat_|glpat-|sk-|xox[abprs]-|AKIA|ASIA|AIza)")
_TOKEN_SHAPED_RE = re.compile(r"^[A-Za-z0-9_+/=-]{24,}$")
_ASSIGNMENT_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_.-]*)=(.*)$", re.DOTALL)
_SAFE_WORD_RE = re.compile(r"^[A-Za-z_-]{1,32}$")
_TOOL_FILTER_KEYS = ("include", "exclude")
_SCALAR_SHARED_FIELDS: dict[str, Callable[[Any], bool]] = {
    "timeout": lambda v: isinstance(v, (int, float)) and not isinstance(v, bool),
    "connect_timeout": lambda v: isinstance(v, (int, float)) and not isinstance(v, bool),
    "keepalive_interval": lambda v: isinstance(v, (int, float)) and not isinstance(v, bool),
    "ssl_verify": lambda v: isinstance(v, bool),
    "lazy": lambda v: isinstance(v, bool),
    "skip_preflight": lambda v: isinstance(v, bool),
    "supports_parallel_tool_calls": lambda v: isinstance(v, bool),
    "transport": lambda v: isinstance(v, str) and bool(_SAFE_WORD_RE.match(v)),
    "type": lambda v: isinstance(v, str) and bool(_SAFE_WORD_RE.match(v)),
    "log_level": lambda v: isinstance(v, str) and bool(_SAFE_WORD_RE.match(v)),
}


class SharedDefinitionConflict(ValueError):
    pass

_definitions_cache: dict[str, tuple[tuple[int, int], dict[str, dict]]] = {}
_definitions_cache_lock = threading.Lock()


def catalog_dir(home: str | Path | None = None) -> Path:
    return get_shared_catalog_dir(home=home)


def catalog_active(home: str | Path | None = None) -> bool:
    return (catalog_dir(home) / CATALOG_MIGRATED_MARKER).is_file()


def catalog_skills_dir(home: str | Path | None = None) -> Path:
    return catalog_dir(home) / "skills"


def mcp_definitions_path(home: str | Path | None = None) -> Path:
    return catalog_dir(home) / MCP_DEFINITIONS_FILE


@contextmanager
def catalog_lock() -> Iterator[None]:
    from tools.skill_usage import skill_file_lock

    with skill_file_lock(get_shared_root() / CATALOG_LOCK_FILE):
        yield


def _load_definitions_file(path: Path) -> dict[str, dict]:
    try:
        raw = yaml.safe_load(path.read_text(encoding="utf-8-sig"))
    except FileNotFoundError:
        return {}
    if raw is None:
        return {}
    if not isinstance(raw, dict):
        raise ValueError(f"{path} must contain a mapping of server name to definition")
    return {str(name): dict(entry) for name, entry in raw.items() if isinstance(entry, dict)}


def read_mcp_definitions() -> dict[str, dict]:
    path = mcp_definitions_path()
    try:
        stat = path.stat()
    except FileNotFoundError:
        return {}
    signature = (stat.st_mtime_ns, stat.st_size)
    key = str(path)
    with _definitions_cache_lock:
        cached = _definitions_cache.get(key)
    if cached is not None and cached[0] == signature:
        return copy.deepcopy(cached[1])
    definitions = _load_definitions_file(path)
    with _definitions_cache_lock:
        _definitions_cache[key] = (signature, definitions)
    return copy.deepcopy(definitions)


def write_mcp_definitions_locked(definitions: dict[str, dict]) -> None:
    from utils import atomic_yaml_write

    path = mcp_definitions_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    atomic_yaml_write(path, definitions, create_mode=0o600)
    with _definitions_cache_lock:
        _definitions_cache.pop(str(path), None)


def update_mcp_definitions(mutate: Callable[[dict[str, dict]], T]) -> T:
    with catalog_lock():
        definitions = _load_definitions_file(mcp_definitions_path())
        before = copy.deepcopy(definitions)
        result = mutate(definitions)
        if definitions != before:
            write_mcp_definitions_locked(definitions)
        return result


def _has_url_secret(text: str) -> bool:
    try:
        parts = urlsplit(text)
        parts.port
    except ValueError:
        return True
    return bool(parts.username or parts.password or parts.query or parts.fragment)


def _token_shaped(text: str) -> bool:
    if _TOKEN_PREFIX_RE.match(text):
        return True
    if text.startswith(("/", ".", "@")) or not _TOKEN_SHAPED_RE.match(text):
        return False
    return any(c.isdigit() for c in text) and any(c.isalpha() for c in text)


def _text_looks_secret(text: str) -> bool:
    if "://" in text and _has_url_secret(text):
        return True
    if _token_shaped(text):
        return True
    assignment = _ASSIGNMENT_RE.match(text)
    return bool(assignment) and (
        bool(_SECRET_NAME_RE.search(assignment.group(1))) or _text_looks_secret(assignment.group(2)))


def _args_are_shareable(args: Any) -> bool:
    if not isinstance(args, list) or not all(isinstance(a, str) for a in args):
        return False
    awaiting_secret_value = False
    for arg in args:
        if awaiting_secret_value or _text_looks_secret(arg):
            return False
        if not arg.startswith("-"):
            continue
        flag, has_value, value = arg.lstrip("-").partition("=")
        if _SECRET_NAME_RE.search(flag):
            if has_value:
                return False
            awaiting_secret_value = True
        elif has_value and _text_looks_secret(value):
            return False
    return not awaiting_secret_value


def _url_is_shareable(url: Any) -> bool:
    if not isinstance(url, str) or _has_url_secret(url):
        return False
    return not any(_token_shaped(segment) for segment in urlsplit(url).path.split("/") if segment)


def _tools_are_shareable(tools: Any) -> bool:
    return isinstance(tools, dict) and all(
        key in _TOOL_FILTER_KEYS and isinstance(value, list) and all(isinstance(v, str) for v in value)
        for key, value in tools.items())


def _command_is_shareable(command: Any) -> bool:
    return isinstance(command, str) and not _text_looks_secret(command)


_STRUCTURAL_CHECKS: dict[str, Callable[[Any], bool]] = {
    "command": _command_is_shareable,
    "args": _args_are_shareable,
    "url": _url_is_shareable,
    "tools": _tools_are_shareable,
    **_SCALAR_SHARED_FIELDS,
}


def definition_from_server(server_config: dict) -> dict:
    return split_bot_secrets(server_config)[0]


def has_transport(entry: Any) -> bool:
    return isinstance(entry, dict) and any(key in entry for key in TRANSPORT_KEYS)


def split_bot_secrets(server_config: dict) -> tuple[dict, dict]:
    shared: dict = {}
    bot_only: dict = {}
    for key, value in server_config.items():
        if key in BOT_FLAG_KEYS:
            continue
        check = _STRUCTURAL_CHECKS.get(key)
        target = shared if check is not None and check(value) else bot_only
        target[key] = copy.deepcopy(value)
    return shared, bot_only


def merge_server(shared: dict, bot_entry: dict) -> dict:
    merged = copy.deepcopy(shared)
    for key, value in bot_entry.items():
        if isinstance(value, dict) and isinstance(merged.get(key), dict):
            merged[key] = merge_server(merged[key], value)
        else:
            merged[key] = copy.deepcopy(value)
    return merged


def effective_mcp_servers(bot_servers: Any) -> dict:
    if not isinstance(bot_servers, dict):
        return {}
    if not catalog_active():
        return bot_servers
    definitions = read_mcp_definitions()
    effective: dict = {}
    for name, entry in bot_servers.items():
        shared = definitions.get(str(name))
        if shared is not None and isinstance(entry, dict):
            effective[name] = merge_server(shared, entry)
        elif shared is not None and entry is None:
            effective[name] = copy.deepcopy(shared)
        elif has_transport(entry) or not isinstance(entry, dict):
            effective[name] = entry
    return effective


def visible_mcp_servers(bot_servers: Any) -> dict:
    servers = bot_servers if isinstance(bot_servers, dict) else {}
    if not catalog_active():
        return servers
    visible = effective_mcp_servers(servers)
    for name, definition in read_mcp_definitions().items():
        if name not in visible:
            visible[name] = {**definition, "enabled": False}
    return visible


def shared_mcp_names() -> set[str]:
    return set(read_mcp_definitions()) if catalog_active() else set()


def prune_stale_bot_entries(bot_servers: dict) -> dict:
    if not catalog_active():
        return bot_servers
    known = set(read_mcp_definitions())
    return {
        name: entry for name, entry in bot_servers.items()
        if name in known or has_transport(entry) or not isinstance(entry, dict)
    }


def _other_profiles_using(name: str) -> list[str]:
    from hermes_cli.config import read_user_config_raw
    from hermes_cli.profiles import _get_default_hermes_home, _iter_named_profile_dirs
    from hermes_constants import get_hermes_home

    current = get_hermes_home().resolve()
    homes = [("default", _get_default_hermes_home()), *((p.name, p) for p in _iter_named_profile_dirs())]
    users: list[str] = []
    for label, home in homes:
        if not home.is_dir() or home.resolve() == current:
            continue
        try:
            servers = read_user_config_raw(home / "config.yaml").get("mcp_servers")
        except (OSError, ValueError, yaml.YAMLError):
            logger.warning("Cannot read mcp_servers of profile %s; treating it as using %s", label, name)
            users.append(label)
            continue
        if isinstance(servers, dict) and name in servers:
            users.append(label)
    return users


def _guard_shared_rewrite(definitions: dict[str, dict], name: str, definition: dict) -> None:
    existing = definitions.get(name)
    if existing is None or existing == definition or not _other_profiles_using(name):
        return
    raise SharedDefinitionConflict(
        f"{name} is shared with other bots; choose a different name or change it from Settings")


def save_server(bot_servers: dict, name: str, server_config: dict, *, force_shared: bool = False) -> dict:
    definition, bot_only = split_bot_secrets(server_config)
    if force_shared:
        require_profile_admin_grant("mcp_replace_shared", name)

    def store(definitions: dict[str, dict]) -> None:
        if not force_shared:
            _guard_shared_rewrite(definitions, name, definition)
        definitions[name] = definition

    update_mcp_definitions(store)
    updated = dict(bot_servers)
    updated[name] = {"enabled": server_config.get("enabled", True), **bot_only}
    return prune_stale_bot_entries(updated)


def replace_servers(servers: dict[str, dict], *, force_shared: bool = False) -> dict:
    split = {name: split_bot_secrets(cfg) for name, cfg in servers.items()}
    if force_shared:
        require_profile_admin_grant("mcp_replace_shared")

    def store(definitions: dict[str, dict]) -> None:
        if not force_shared:
            for name, (shared, _) in split.items():
                _guard_shared_rewrite(definitions, name, shared)
        definitions.update({name: shared for name, (shared, _) in split.items()})

    update_mcp_definitions(store)
    return {name: {"enabled": servers[name].get("enabled", True), **bot_only} for name, (_, bot_only) in split.items()}


def remove_server(bot_servers: dict, name: str, *, everywhere: bool = False) -> tuple[dict, bool]:
    if everywhere:
        require_profile_admin_grant("mcp_remove_everywhere", name)
        existed = update_mcp_definitions(lambda definitions: definitions.pop(name, None) is not None)
    else:
        existed = name in read_mcp_definitions()
    existed = existed or name in bot_servers
    remaining = {k: v for k, v in bot_servers.items() if k != name}
    return prune_stale_bot_entries(remaining), existed


def _read_applied_opt_outs(home: Path) -> set[str]:
    try:
        text = (home / OPT_OUT_APPLIED_FILE).read_text(encoding="utf-8-sig")
    except FileNotFoundError:
        return set()
    return {line.strip() for line in text.splitlines() if line.strip()}


def apply_bundled_opt_out(home: Path, bundled_names: set[str]) -> list[str]:
    from agent.skill_utils import ESSENTIAL_SKILLS
    from hermes_cli.shared_catalog_config import edit_config_keys, skill_list_updates
    from utils import atomic_write_text

    if not catalog_active(home) or not (home / NO_BUNDLED_SKILLS_MARKER).exists():
        return []
    applied = _read_applied_opt_outs(home)
    fresh = sorted(bundled_names - ESSENTIAL_SKILLS - applied)
    if not fresh:
        return []
    edit_config_keys(home / "config.yaml", lambda config: skill_list_updates(config, disable_add=fresh))
    atomic_write_text(home / OPT_OUT_APPLIED_FILE, "\n".join(sorted(applied | set(fresh))) + "\n")
    return fresh
