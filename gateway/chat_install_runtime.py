from __future__ import annotations

import logging

from gateway.chat_install_service import ChatInstallService, ReloadOutcome
from gateway.chat_install_store import ChatInstallStore
from gateway.oauth_client_setup import GOOGLE_REDIRECT_PATH
from tools.connectors.mcp_oauth_redirect import GATEWAY_CALLBACK_PATH as MCP_OAUTH_REDIRECT_PATH
from tui_gateway.chat_install import REDIRECT_PATH

_REDACTED_PATHS = (REDIRECT_PATH, GOOGLE_REDIRECT_PATH, MCP_OAUTH_REDIRECT_PATH)


class RedactInstallCallbackQuery(logging.Filter):
    def filter(self, record: logging.LogRecord) -> bool:
        args = record.args
        if isinstance(args, tuple) and len(args) >= 3 and isinstance(args[2], str) and args[2].startswith(_REDACTED_PATHS):
            record.args = (*args[:2], args[2].split("?", 1)[0], *args[3:])
        return True


def _scope_name(profile: str) -> str | None:
    return None if profile in ("", "default") else profile


class MessagingAdapterControl:
    def apply_env(self, profile: str, platform_id: str, env: dict[str, str], clear: list[str]) -> None:
        from hermes_cli.web_routers import messaging
        entry = messaging._require_platform(platform_id)
        with messaging._profile_scope(_scope_name(profile)):
            messaging._apply_platform_update(platform_id, entry, messaging._env_value_rules(platform_id),
                                             env, clear, bool(env))

    def reload(self, profile: str) -> ReloadOutcome:
        from tui_gateway.methods_messaging_slack import _slack_reload
        result = _slack_reload(_scope_name(profile))
        if result.get("hot_served"):
            return ReloadOutcome.live
        return ReloadOutcome.restarting if result.get("restart_started") else ReloadOutcome.not_started


def bot_profile_scope(bot: str):
    from hermes_cli.web_routers import messaging
    return messaging._profile_scope(_scope_name(bot))


def public_url_for(home) -> str | None:
    from gateway.webapp_listener import webapp_settings
    return webapp_settings(home).public_url or None


def redirect_url_for(home) -> str | None:
    public_url = public_url_for(home)
    if not (public_url or "").startswith("https://"):
        return None
    return public_url.rstrip("/") + REDIRECT_PATH


def build_service(home) -> ChatInstallService:
    from tui_gateway.chat_providers import provider_for
    return ChatInstallService(
        store=ChatInstallStore(home),
        provider_for=lambda provider_id: provider_for(provider_id, redirect_url=redirect_url_for(home)),
        control=MessagingAdapterControl(), public_url=lambda: public_url_for(home), bot_scope=bot_profile_scope)
