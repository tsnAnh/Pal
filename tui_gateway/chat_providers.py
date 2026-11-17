from __future__ import annotations

from typing import Any, Callable

from tui_gateway.chat_install import ChatProvider, ChatProviderError


def _slack(**deps: Any) -> ChatProvider:
    from gateway.chat_slack.provider import SlackProvider

    return SlackProvider(**deps)


PROVIDER_FACTORIES: dict[str, Callable[..., ChatProvider]] = {"slack": _slack}


def provider_for(provider_id: str, **deps: Any) -> ChatProvider:
    factory = PROVIDER_FACTORIES.get(provider_id)
    if factory is None:
        raise ChatProviderError(provider_id, "provider_for")
    return factory(**deps)
