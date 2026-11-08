from __future__ import annotations

import logging

from hermes_cli.dashboard_auth.registry import list_providers

logger = logging.getLogger(__name__)


def revoke_refresh_token(refresh_token: str) -> int:
    revoked = 0
    for provider in list_providers():
        try:
            provider.revoke_session(refresh_token=refresh_token)
            revoked += 1
        except Exception:
            logger.exception("dashboard-auth: revoke on %r failed", provider.name)
    return revoked
