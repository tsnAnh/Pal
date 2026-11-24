from __future__ import annotations

import contextvars
import functools
import logging
import os
import threading
import time
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Callable, Iterator, TypeVar

from hermes_cli.shared_catalog import (
    CONNECTORS_ADOPTED_FILE, catalog_active, catalog_dir, catalog_lock, home_is_root, hosted_scope, is_root_owned,
    root_entries, root_home, shared_mcp_names)

logger = logging.getLogger(__name__)

F = TypeVar("F", bound=Callable[..., Any])

ADOPTION_RECHECK_SECONDS = 60.0
_adoption_checked: dict[str, float] = {}
_adoption_checked_lock = threading.Lock()
_requested_home: contextvars.ContextVar[Path | None] = contextvars.ContextVar("owner_write_requested_home", default=None)


def _profile_has_entry(name: str) -> bool:
    from hermes_cli.config_backend import read_config_doc_readonly
    from hermes_constants import get_hermes_home

    try:
        servers = read_config_doc_readonly(get_hermes_home() / "config.yaml").get("mcp_servers")
    except FileNotFoundError:
        return False
    return isinstance(servers, dict) and isinstance(servers.get(name), dict)


def _owner_writes_to_root(name: Any) -> bool:
    from tools.mcp_accounts import registration_name

    if hosted_scope() or home_is_root():
        return False
    if not isinstance(name, str):
        return True
    return is_root_owned(name) or not _profile_has_entry(registration_name(name))


def owner_state_home(name: Any) -> Path:
    from hermes_constants import get_hermes_home

    return root_home() if _owner_writes_to_root(name) else get_hermes_home()


@contextmanager
def owner_state_scope(name: Any = None) -> Iterator[None]:
    if not _owner_writes_to_root(name):
        yield
        return
    from agent.runtime_scope import bind_profile_scope
    from hermes_constants import get_hermes_home

    token = _requested_home.set(get_hermes_home())
    try:
        with bind_profile_scope(root_home(), hydrate_secrets=False):
            yield
    finally:
        _requested_home.reset(token)


@contextmanager
def owner_write_scope(name: Any = None) -> Iterator[None]:
    if hosted_scope() or home_is_root():
        yield
        return
    with owner_state_scope(name):
        yield


def requested_profile_home() -> Path:
    from hermes_constants import get_hermes_home

    return _requested_home.get() or get_hermes_home()


def serves_from_root(name: Any) -> bool:
    return not home_is_root() and is_root_owned(name)


def _root_secrets() -> dict[str, str]:
    from agent.secret_scope import build_profile_secret_scope
    from hermes_cli.env_loader import hydrate_profile_secret_sources

    try:
        hydrate_profile_secret_sources(root_home())
    except Exception:  # health: allow BLE001 -- a source that cannot answer leaves the root .env as the only secrets
        logger.warning("The root profile's secret sources could not be read; using its .env alone", exc_info=True)
    return build_profile_secret_scope(root_home())


def root_secret_resolver() -> Callable[[str, str | None], str | None]:
    secrets: dict[str, str] | None = None

    def read(var: str, default: str | None = None) -> str | None:
        from agent.secret_scope import _is_global_env

        nonlocal secrets
        if _is_global_env(var):
            return os.environ.get(var, default)
        if secrets is None:
            secrets = _root_secrets()
        return secrets.get(var, default)

    return read


def root_secret_reader(name: Any) -> Callable[[str, str | None], str | None] | None:
    return root_secret_resolver() if serves_from_root(name) else None


def owner_write(name_of: Callable[..., Any] = lambda name=None, *_args, **_kwargs: name) -> Callable[[F], F]:
    def decorate(write: F) -> F:
        @functools.wraps(write)
        def scoped(*args, **kwargs):
            with owner_write_scope(name_of(*args, **kwargs)):
                return write(*args, **kwargs)

        return scoped

    return decorate


def _local_connections(home: Path, name: str) -> list[str]:
    from tools.mcp_accounts import AccountError, server_name
    from tools.mcp_oauth import ACCOUNT_DIR_NAME, TOKEN_DIR_NAME, HermesTokenStorage

    connections = [name] if HermesTokenStorage(name, hermes_home=home, own_home_only=True).state_paths() else []
    accounts = home / TOKEN_DIR_NAME / ACCOUNT_DIR_NAME / name
    if not accounts.is_dir():
        return connections
    for alias in sorted({path.name.split(".", 1)[0] for path in accounts.iterdir() if path.is_file()}):
        try:
            connections.append(server_name(name, alias))
        except AccountError:
            logger.warning("Ignoring a connector account file with an invalid name under profile state of %s", name)
    return connections


def referenced_env_vars(value: Any) -> set[str]:
    from hermes_cli.config import _ENV_VAR_NAME_RE
    from tools.mcp_tool_common import _env_ref_name
    from tools.mcp_tool_config import _CONTEXT_VAR_RESOLVERS, _ENV_VAR_PATTERN

    if isinstance(value, str):
        names = {_env_ref_name(m.group(1)) for m in _ENV_VAR_PATTERN.finditer(value)
                 if m.group(1).strip() not in _CONTEXT_VAR_RESOLVERS}
        return {name for name in names if _ENV_VAR_NAME_RE.match(name)}
    if isinstance(value, dict):
        return set().union(*(referenced_env_vars(item) for item in value.values()))
    if isinstance(value, list):
        return set().union(*(referenced_env_vars(item) for item in value))
    return set()


def _profile_entry(home: Path, name: str) -> dict | None:
    from hermes_cli.config import read_user_config_raw

    servers = read_user_config_raw(home / "config.yaml").get("mcp_servers")
    entry = servers.get(name) if isinstance(servers, dict) else None
    return entry if isinstance(entry, dict) else None


def _entry_secrets(home: Path, name: str, entry: dict) -> tuple[set[str], dict[str, str]]:
    from agent.secret_scope import load_env_file
    from hermes_cli.shared_catalog import merge_server, read_mcp_definitions

    referenced = referenced_env_vars(merge_server(read_mcp_definitions().get(name, {}), entry))
    return referenced, load_env_file(home / ".env")


def _copy_secrets(label: str, referenced: set[str], source: dict[str, str]) -> None:
    from agent.runtime_scope import bind_profile_scope
    from agent.secret_scope import load_env_file
    from hermes_cli.config import save_env_value

    root_env = load_env_file(root_home() / ".env")
    copied = sorted(var for var in referenced if var in source and var not in root_env)
    if not copied:
        return
    with bind_profile_scope(root_home(), hydrate_secrets=False):
        for var in copied:
            save_env_value(var, source[var])
    logger.info("Copied %s of profile %s into the root profile", ", ".join(copied), label)


def _adopt_entry(label: str, home: Path, name: str, *, needs_secrets: bool = False) -> bool:
    from hermes_cli.shared_catalog_config import dotted_key, edit_config_keys

    entry = _profile_entry(home, name)
    if entry is None:
        return False
    referenced, source = _entry_secrets(home, name, entry)
    if needs_secrets and not referenced <= source.keys() | _root_env_names():
        return False

    def edit(config: dict) -> dict[str, Any]:
        root_servers = config.get("mcp_servers")
        if isinstance(root_servers, dict) and name in root_servers:
            return {}
        return {dotted_key("mcp_servers", name): entry}

    if not edit_config_keys(root_home() / "config.yaml", edit):
        return False
    logger.info("Adopted the %s entry of profile %s into the root profile", name, label)
    _copy_secrets(label, referenced, source)
    return True


def _root_env_names() -> set[str]:
    from agent.secret_scope import load_env_file

    return set(load_env_file(root_home() / ".env"))


def _adoptable_entries(homes: list[Path], names: list[str]) -> list[tuple[str, Path, str]]:
    from tools.mcp_tool_common import mcp_server_enabled

    wanted = [name for name in names if name not in root_entries()]
    found = []
    for home in homes:
        for name in wanted:
            entry = _profile_entry(home, name)
            if entry is not None and mcp_server_enabled(entry):
                found.append((home.name, home, name))
    return found


def _legacy_connector_names() -> list[str]:
    from hermes_cli.pal_connectors import load_pal_connectors

    return sorted(shared_mcp_names() & {entry.id for entry in load_pal_connectors()})


def adoption_closed() -> bool:
    return (catalog_dir() / CONNECTORS_ADOPTED_FILE).is_file()


def _adopt_profile_state() -> list[tuple[str, str]]:
    from hermes_cli.profiles import _iter_named_profile_dirs
    from tools.mcp_oauth import HermesTokenStorage

    names = _legacy_connector_names()
    homes = _iter_named_profile_dirs()
    adopted: list[tuple[str, str]] = []
    for home in homes:
        for name in names:
            for connection in _local_connections(home, name):
                source = HermesTokenStorage(connection, hermes_home=home, own_home_only=True)
                target = HermesTokenStorage(connection)
                if not source.state_paths() or target.state_paths():
                    continue
                if target.absorb(source):
                    adopted.append((home.name, connection))
                    logger.info("Adopted the %s login of profile %s into the root profile", connection, home.name)
                    _adopt_entry(home.name, home, name)
    for label, home, name in _adoptable_entries(homes, names):
        _adopt_entry(label, home, name, needs_secrets=True)
    return adopted


def adopt_profile_connectors() -> list[tuple[str, str]]:
    from utils import atomic_write_text

    if not catalog_active() or adoption_closed():
        return []
    with catalog_lock():
        if adoption_closed():
            return []
        adopted = _adopt_profile_state()
        atomic_write_text(catalog_dir() / CONNECTORS_ADOPTED_FILE, "")
    return adopted


def adopt_profile_connectors_if_due() -> list[tuple[str, str]]:
    if adoption_closed():
        return []
    key = str(root_home())
    now = time.monotonic()
    with _adoption_checked_lock:
        last = _adoption_checked.get(key)
        if last is not None and now - last < ADOPTION_RECHECK_SECONDS:
            return []
        _adoption_checked[key] = now
    return adopt_profile_connectors()
