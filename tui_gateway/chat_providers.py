from __future__ import annotations

from typing import Any, Callable

from tui_gateway.chat_install import ChatProvider, ChatProviderError


class UnknownProvider(ChatProviderError):
    pass


def _slack(**deps: Any) -> ChatProvider:
    from gateway.chat_slack.provider import SlackProvider

    return SlackProvider(**deps)


def _discord(*, redirect_url: str | None = None, **deps: Any) -> ChatProvider:
    from gateway.chat_discord.provider import DiscordProvider

    return DiscordProvider(**deps)


PROVIDER_FACTORIES: dict[str, Callable[..., ChatProvider]] = {"slack": _slack, "discord": _discord}


def provider_for(provider_id: str, **deps: Any) -> ChatProvider:
    factory = PROVIDER_FACTORIES.get(provider_id)
    if factory is None:
        raise UnknownProvider(provider_id, "provider_for")
    return factory(**deps)


def registered_provider_ids() -> list[str]:
    return list(PROVIDER_FACTORIES)
