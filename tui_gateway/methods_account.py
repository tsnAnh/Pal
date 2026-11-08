from __future__ import annotations

import logging

from .method_ctx import HandlerRegistry, bind_module

logger = logging.getLogger(__name__)

_registry = HandlerRegistry()
method = _registry.method
_profile_scoped = _registry.profile_scoped


@method("account.subscriptions")
@_profile_scoped
def _(rid, params: dict) -> dict:
    from hermes_cli.account_subscriptions import build_account_subscriptions

    try:
        return _ok(rid, build_account_subscriptions(refresh=bool(params.get("refresh"))))
    except Exception:
        logger.warning("account.subscriptions failed", exc_info=True)
        return _err(rid, 5099, "could not read account subscriptions")


def register(server) -> None:
    bind_module(globals(), server, skip=("_",))
