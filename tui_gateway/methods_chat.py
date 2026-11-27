"""``chat.*``: install a bot into a chat workspace (Slack first) and bind it to channels.

Owner connections only. Orchestration lives in ``gateway/chat_install_service.py``; the redirect that
completes an install is ``hermes_cli/web_routers/chat_install.py``. No result or error carries a token,
an authorization code or provider text. Bodies are rebound onto server.py's globals (method_ctx.bind_module).
"""

import logging

from .method_ctx import HandlerRegistry, bind_module

logger = logging.getLogger(__name__)
_registry = HandlerRegistry()
method = _registry.method
_profile_scoped = _registry.profile_scoped

_CHAT_CODES = {
    "owner_only": 4403, "provider_unknown": 4404, "no_installation": 4404, "invalid_event": 4101,
    "stale_revision": 4409, "needs_public_url": 4412, "not_implemented": 4501, "provider_failed": 5104,
    "invalid_input": 4102, "invalid_image": 4413, "not_joined": 4405, "not_found": 4406,
}
_CHAT_MESSAGES = {
    "owner_only": "Only the owner can set up chat apps",
    "provider_unknown": "That chat app is not available here",
    "no_installation": "This bot is not installed there yet",
    "invalid_event": "That step does not apply right now",
    "stale_revision": "Setup changed on another device. Refresh and try again",
    "needs_public_url": "Set this gateway's public https address first",
    "not_implemented": "That is not supported for this chat app yet",
    "provider_failed": "The chat app did not respond. Try again",
    "invalid_input": "Check what you entered and try again",
    "invalid_image": "That picture can't be used. Try a different one",
    "not_joined": "The bot is not in that channel yet",
    "not_found": "That item is no longer there",
}


def _chat_error(rid, reason: str, *, state=None, fix=None):
    data = {"reason": reason}
    if state is not None:
        data["state"] = state.model_dump(mode="json")
    if fix is not None:
        data["next_action"] = fix.model_dump(mode="json")
    return _err(rid, _CHAT_CODES[reason], _CHAT_MESSAGES[reason], data=data)


def _chat_owner_refusal(rid):
    refusal = _owner_connection_refusal(rid)
    if refusal is not None:
        return _chat_error(rid, "owner_only")
    return None


def _chat_status_body(state, installation, adapter=None) -> dict:
    return {"state": state.model_dump(mode="json"),
            "installation": installation.model_dump(mode="json") if installation is not None else None,
            "adapter": adapter.model_dump(mode="json") if adapter is not None else None}


def _chat_run(rid, params: dict, call):
    if refusal := _chat_owner_refusal(rid):
        return refusal
    from gateway.chat_install_runtime import build_service
    from gateway.chat_install_service import ChatServiceError
    try:
        return _ok(rid, call(build_service(_hermes_home), _bot_settings_profile_name(params)))
    except ChatServiceError as exc:
        return _chat_error(rid, exc.reason.value, state=exc.state, fix=exc.fix)
    except Exception as exc:  # health: allow BLE001 -- provider text must not reach the wire or the log, so only the exception type is logged
        logger.warning("chat call failed (%s)", type(exc).__name__)
        return _chat_error(rid, "provider_failed")


def _chat_target(params: dict) -> tuple[str, str]:
    return params["provider_id"], str(params.get("workspace") or "")


@method("chat.provider.list")
@_profile_scoped
def _(rid, params: dict) -> dict:
    def call(service, bot):
        return {"providers": [c.model_dump(mode="json") for c in service.provider_capabilities()]}
    return _chat_run(rid, params, call)


@method("chat.install.status")
@_profile_scoped
def _(rid, params: dict) -> dict:
    def call(service, bot):
        state, installation = service.status(bot, *_chat_target(params))
        return _chat_status_body(state, installation, service.live_adapter(installation))
    return _chat_run(rid, params, call)


@method("chat.install.reconnect")
@_profile_scoped
def _(rid, params: dict) -> dict:
    return _chat_run(rid, params, lambda service, bot: _chat_status_body(*service.reconnect(bot, *_chat_target(params))))


@method("chat.install.begin")
@_profile_scoped
def _(rid, params: dict) -> dict:
    from tools.connectors.app_scheme import AppScheme
    scheme = AppScheme.parse(params.get("app_scheme"))
    return _chat_run(rid, params, lambda service, bot: _chat_status_body(*service.begin(bot, *_chat_target(params), scheme)))


@method("chat.install.advance")
@_profile_scoped
def _(rid, params: dict) -> dict:
    from tools.connectors.app_scheme import AppScheme
    from tui_gateway.contracts.chat_provider import ProviderCapability, SetupEventKind
    manual = params.get("manual_step")
    return _chat_run(rid, params, lambda service, bot: _chat_status_body(*service.advance(
        bot, *_chat_target(params), SetupEventKind(params["event"]), int(params["expected_revision"]),
        ProviderCapability(manual) if manual else None, params.get("vault_item_id"),
        params.get("refresh_vault_item_id"), params.get("owner_member_id"), AppScheme.parse(params.get("app_scheme")))))


@method("chat.spaces.list")
@_profile_scoped
def _(rid, params: dict) -> dict:
    return _chat_run(rid, params, lambda service, bot: {
        "spaces": [s.model_dump(mode="json") for s in service.spaces(bot, *_chat_target(params))]})


@method("chat.space.join")
@_profile_scoped
def _(rid, params: dict) -> dict:
    def call(service, bot):
        result = service.join(bot, *_chat_target(params), params["space_id"], bool(params.get("hello")))
        return {"outcome": result.outcome.value, "next_action": result.next_action.model_dump(mode="json")}
    return _chat_run(rid, params, call)


@method("chat.binding.list")
@_profile_scoped
def _(rid, params: dict) -> dict:
    return _chat_run(rid, params, lambda service, bot: {
        "bindings": [b.model_dump(mode="json") for b in service.bindings(bot)]})


@method("chat.install.update_identity")
@_profile_scoped
def _(rid, params: dict) -> dict:
    def call(service, bot):
        result = service.update_identity(bot, *_chat_target(params))
        return {"outcome": result.outcome.value, "identity": result.identity.model_dump(mode="json"),
                "next_action": result.next_action.model_dump(mode="json")}
    return _chat_run(rid, params, call)


@method("chat.install.revoke")
@_profile_scoped
def _(rid, params: dict) -> dict:
    return _chat_run(rid, params, lambda service, bot: _chat_status_body(*service.revoke(bot, *_chat_target(params))))


def register(server) -> None:
    bind_module(globals(), server, skip=("_",))
