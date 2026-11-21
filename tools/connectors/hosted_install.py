from __future__ import annotations

import logging
from typing import Any, Optional

from tools.connectors import hosted_signin, hosted_surface
from tools.connectors.gateway import config as gateway_config

logger = logging.getLogger(__name__)


def _names() -> Optional[set[str]]:
    try:
        from tools.connectors.gateway.client import ConnectorClient

        if not gateway_config.connectors_available():
            return None
        return {str(item.get("connector", "")).lower()
                for item in ConnectorClient().list_connectors() if isinstance(item, dict)}
    except Exception as exc:  # health: allow BLE001 -- unchanged boundary moved from targets.hosted_names: any gateway failure means no routing check
        logger.debug("connector list for the routing check failed: %s", exc)
        return None


def _reissue(operation: Any, stale: Any, initiator: Optional[str]) -> None:
    from tools.connectors.contract import Actor
    from tools.connectors.managed import CARD_RETRY, managed_client, mint

    client = managed_client(creates_guest=True, initiator=initiator or CARD_RETRY, call=operation.call)
    mint(client, operation, stale, reinitiate=True, actor=Actor.user)


def install() -> None:
    hosted_signin.register()
    hosted_surface.install(hosted_surface.HostedSurface(
        available=lambda: gateway_config.connectors_available(), names=_names, reissue=_reissue))
