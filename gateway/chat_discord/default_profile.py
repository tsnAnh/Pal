from __future__ import annotations

import logging
from collections.abc import Callable, Iterator
from contextlib import AbstractContextManager, contextmanager
from typing import Any

from hermes_constants import get_default_hermes_root

logger = logging.getLogger(__name__)

ALLOWED_USERS_ENV = "DISCORD_ALLOWED_USERS"
PROFILE_ROUTES_KEY = "profile_routes"
PLATFORM = "discord"
ScopeFactory = Callable[[], AbstractContextManager[object]]


@contextmanager
def default_profile_scope() -> Iterator[None]:
    from agent.runtime_scope import bind_profile_scope
    with bind_profile_scope(get_default_hermes_root(), hydrate_secrets=False):
        yield


def route_name(bot: str, channel_id: str) -> str:
    return f"pal-discord-{bot}-{channel_id}"


def direct_route_name(channel_id: str) -> str:
    return f"pal-discord-dm-{channel_id}"


class RouteConflict(Exception):
    pass


class ProfileRoutes:
    def __init__(self, scope: ScopeFactory = default_profile_scope):
        self._scope = scope

    def _read(self, config: dict[str, Any]) -> list[dict[str, Any]]:
        raw = config.get(PROFILE_ROUTES_KEY)
        return [dict(entry) for entry in raw if isinstance(entry, dict)] if isinstance(raw, list) else []

    def entries(self) -> list[dict[str, Any]]:
        from hermes_cli.config import read_raw_config_readonly
        with self._scope():
            return self._read(read_raw_config_readonly())

    def set(self, bot: str, channel_id: str) -> bool:
        return self._put({"name": route_name(bot, channel_id), "platform": PLATFORM, "chat_id": channel_id,
                          "profile": bot})

    def remove(self, bot: str, channel_id: str) -> bool:
        return self._drop(route_name(bot, channel_id))

    def direct_bot(self, channel_id: str) -> str | None:
        name = direct_route_name(channel_id)
        return next((str(e["profile"]) for e in self.entries() if e.get("name") == name and e.get("profile")), None)

    def set_direct(self, channel_id: str, bot: str) -> bool:
        return self._put({"name": direct_route_name(channel_id), "platform": PLATFORM, "chat_id": channel_id,
                          "profile": bot})

    def clear_direct(self, channel_id: str) -> bool:
        return self._drop(direct_route_name(channel_id))

    def _put(self, wanted: dict[str, Any]) -> bool:
        from hermes_cli.config import load_config, save_config
        with self._scope():
            config = load_config()
            current = self._read(config)
            clash = next((e for e in current if e.get("platform") == PLATFORM and str(e.get("chat_id")) == wanted["chat_id"]
                          and not e.get("bot_profile") and e.get("name") != wanted["name"]), None)
            if clash is not None:
                raise RouteConflict(wanted["chat_id"])
            if wanted in current:
                return False
            config[PROFILE_ROUTES_KEY] = [e for e in current if e.get("name") != wanted["name"]] + [wanted]
            save_config(config)
        return True

    def _drop(self, name: str) -> bool:
        from hermes_cli.config import load_config, save_config
        with self._scope():
            config = load_config()
            current = self._read(config)
            kept = [e for e in current if e.get("name") != name]
            if len(kept) == len(current):
                return False
            config[PROFILE_ROUTES_KEY] = kept
            save_config(config)
        return True

    def apply_in_process(self, runner: Any) -> None:
        from gateway.run_platform_reload import reload_routes_verb
        with self._scope():
            reload_routes_verb(runner)({})

    def apply_live(self) -> bool:
        from gateway.control_socket import reload_gateway_routes
        answer = reload_gateway_routes(get_default_hermes_root())
        applied = isinstance(answer, dict) and answer.get("reloaded") is True
        if not applied:
            logger.info("discord routes saved; no live gateway answered, they apply when it starts")
        return applied


class OwnerAllowlist:
    def __init__(self, scope: ScopeFactory = default_profile_scope):
        self._scope = scope

    def users(self) -> list[str]:
        from hermes_cli.config import get_env_value
        with self._scope():
            raw = get_env_value(ALLOWED_USERS_ENV) or ""
        return [user for user in (part.strip() for part in raw.split(",")) if user]

    def ensure(self, owner: str) -> bool:
        from hermes_cli.config import save_env_value
        users = self.users()
        if owner in users:
            return False
        with self._scope():
            save_env_value(ALLOWED_USERS_ENV, ",".join([*users, owner]))
        return True

    def apply_live(self) -> bool:
        from hermes_cli.gateway_multiplex_served import reload_platform_live
        return reload_platform_live(get_default_hermes_root(), PLATFORM, [ALLOWED_USERS_ENV])
