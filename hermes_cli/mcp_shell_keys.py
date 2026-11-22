from __future__ import annotations

import logging
import os
from typing import Any

from hermes_cli.shared_catalog import (
    home_is_root, hosted_scope, is_root_owned, merge_server, read_mcp_definitions, root_entries, root_home)
from hermes_cli.shared_catalog_connectors import (
    referenced_env_vars, requested_profile_home, root_secret_resolver)

logger = logging.getLogger(__name__)

SHELL_IMPORT_BEFORE = frozenset({"test", "configure", "config"})
SHELL_IMPORT_AFTER = frozenset({"add", "install"})


def _shared_entry(name: str) -> dict | None:
    from tools.mcp_accounts import registration_name

    registered = registration_name(name)
    entry = root_entries().get(registered)
    if not isinstance(entry, dict):
        return None
    return merge_server(read_mcp_definitions().get(registered, {}), entry)


def import_shell_keys(name: str) -> list[str]:
    from agent.runtime_scope import bind_profile_scope
    from agent.secret_scope import load_env_file
    from hermes_cli.config import save_env_value, validate_env_var_name_for_write
    from hermes_cli.profile_admin_guard import in_agent_context

    if hosted_scope() or in_agent_context() or not is_root_owned(name):
        return []
    entry = _shared_entry(name)
    if entry is None:
        return []
    resolves = root_secret_resolver()
    active_env = load_env_file(requested_profile_home() / ".env")
    shell_only = [
        var for var in sorted(referenced_env_vars(entry))
        if not resolves(var) and var not in active_env and (os.environ.get(var) or "").strip()]
    saved = []
    with bind_profile_scope(root_home(), hydrate_secrets=False):
        for var in shell_only:
            try:
                validate_env_var_name_for_write(var)
                save_env_value(var, os.environ[var])
            except ValueError:
                logger.warning("Shell key %s was not saved to the root profile", var, exc_info=False)
                continue
            saved.append(var)
    root_env = load_env_file(root_home() / ".env")
    return [var for var in saved if var in root_env]


def unresolved_keys(name: str, entry: dict) -> tuple[list[str], bool]:
    from agent.secret_scope import get_secret

    shared = home_is_root() or is_root_owned(name)
    read = root_secret_resolver() if shared else get_secret
    return [var for var in sorted(referenced_env_vars(entry)) if not read(var, None)], shared


def config_set_command(var: str, *, shared: bool) -> str | None:
    from hermes_cli.config_env_routing import is_env_setting_key
    from hermes_constants import profile_name_for_home

    if not is_env_setting_key(var):
        return None
    home = requested_profile_home()
    if shared:
        prefix = "hermes" if home_is_root(home) else "hermes -p default"
    else:
        profile = profile_name_for_home(home)
        prefix = f"hermes -p {profile}" if profile and profile != "default" else "hermes"
    return f'{prefix} config set {var} "${var}"'


def missing_key_fixes(name: str, entry: Any) -> list[str]:
    if not isinstance(entry, dict):
        return []
    missing, shared = unresolved_keys(name, entry)
    lines = []
    for var in missing:
        command = config_set_command(var, shared=shared)
        lines.append(f"{var} is not set. Fix: {command}" if command else f"{var} is not set. Add it to {_env_hint(shared)}")
    return lines


def _env_hint(shared: bool) -> str:
    home = root_home() if shared else requested_profile_home()
    return str(home / ".env")
