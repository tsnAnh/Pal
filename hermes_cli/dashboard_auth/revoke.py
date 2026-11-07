from __future__ import annotations

import logging

from hermes_cli.dashboard_auth.registry import list_providers

_log = logging.getLogger(__name__)


def revoke_refresh_token(refresh_token: str) -> int:
    revoked = 0
    for provider in list_providers():
        try:
            provider.revoke_session(refresh_token=refresh_token)
            revoked += 1
        except Exception as e:
            _log.warning("dashboard-auth: revoke on %r failed: %s", provider.name, e)
    return revoked
