"""``chat.*`` for the people around a bot: who may talk to it, where its reports go, leaving a channel, its picture, and the
owner desk of questions, hand-offs and sends it holds for its owner.

Owner connections only, through the helpers ``methods_chat.py`` publishes (``_chat_run``, ``_chat_error``). No result or error
carries a token or provider text. Bodies are rebound onto server.py's globals (method_ctx.bind_module).
"""

import logging

from .method_ctx import HandlerRegistry, bind_module

logger = logging.getLogger(__name__)
_registry = HandlerRegistry()
method = _registry.method
_profile_scoped = _registry.profile_scoped


def _parsed(rid, model, params: dict):
    from pydantic import ValidationError
    if refusal := _chat_owner_refusal(rid):
        return None, refusal
    try:
        return model.model_validate(params), None
    except ValidationError:
        return None, _chat_error(rid, "invalid_input")


def _audience_body(answer) -> dict:
    settings, names = answer
    policy = settings.policy
    return {"policy": policy.kind.value, "include_restricted": policy.include_restricted,
            "member_turns_per_hour": policy.member_turns_per_hour, "revision": settings.revision,
            "members": [{"id": member, "name": names.get(member, "")} for member in sorted(policy.members)]}


@method("chat.install.set_icon")
@_profile_scoped
def _(rid, params: dict) -> dict:
    def call(service, bot):
        from gateway.chat_identity_sync import schedule_identity_sync
        service.set_icon(bot, params["provider_id"], params["data"])
        schedule_identity_sync(bot, _hermes_home)
        return {"ok": True}
    return _chat_run(rid, params, call)


@method("chat.space.leave")
@_profile_scoped
def _(rid, params: dict) -> dict:
    return _chat_run(rid, params, lambda service, bot: {
        "outcome": service.leave(bot, *_chat_target(params), params["space_id"]).value})


@method("chat.audience.get")
@_profile_scoped
def _(rid, params: dict) -> dict:
    return _chat_run(rid, params, lambda service, bot: _audience_body(service.audience(bot, *_chat_target(params))))


@method("chat.audience.set")
@_profile_scoped
def _(rid, params: dict) -> dict:
    from tui_gateway.contracts.chat_provider import ChatAudienceSetParams
    parsed, invalid = _parsed(rid, ChatAudienceSetParams, params)
    if invalid is not None:
        return invalid
    from gateway.audience import AudiencePolicyKind
    return _chat_run(rid, params, lambda service, bot: _audience_body(service.set_audience(
        bot, parsed.provider_id, parsed.workspace, AudiencePolicyKind(parsed.policy.value), parsed.members,
        parsed.include_restricted, parsed.member_turns_per_hour, parsed.expected_revision)))


@method("chat.people.list")
@_profile_scoped
def _(rid, params: dict) -> dict:
    def call(service, bot):
        page = service.people(bot, *_chat_target(params), str(params.get("query") or ""), str(params.get("cursor") or ""))
        return {"people": [person.model_dump(mode="json") for person in page.people], "next_cursor": page.next_cursor}
    return _chat_run(rid, params, call)


@method("chat.report.get")
@_profile_scoped
def _(rid, params: dict) -> dict:
    return _chat_run(rid, params, lambda service, bot: {
        "destination": service.report(bot, *_chat_target(params)).model_dump(mode="json")})


@method("chat.report.set")
@_profile_scoped
def _(rid, params: dict) -> dict:
    from tui_gateway.contracts.chat_provider import ChatReportSetParams
    parsed, invalid = _parsed(rid, ChatReportSetParams, params)
    if invalid is not None:
        return invalid
    return _chat_run(rid, params, lambda service, bot: {"destination": service.set_report(
        bot, parsed.provider_id, parsed.workspace, parsed.destination).model_dump(mode="json")})


def _desk_run(rid, params: dict, call):
    if refusal := _chat_owner_refusal(rid):
        return refusal
    from hermes_cli.profiles import get_profile_dir
    try:
        return call(get_profile_dir(_bot_settings_profile_name(params)))
    except Exception as exc:  # health: allow BLE001 -- desk rows carry what members wrote, so only the exception type is logged
        logger.warning("chat desk call failed (%s)", type(exc).__name__)
        return _chat_error(rid, "provider_failed")


@method("chat.desk.list")
@_profile_scoped
def _(rid, params: dict) -> dict:
    from tui_gateway.contracts.chat_provider import ChatDeskListParams
    parsed, invalid = _parsed(rid, ChatDeskListParams, params)
    if invalid is not None:
        return invalid

    def call(home):
        from tui_gateway.desk_wire import listing
        return _ok(rid, {"items": [item.model_dump(mode="json") for item in listing(home, parsed.states, parsed.kinds)]})
    return _desk_run(rid, params, call)


@method("chat.desk.decide")
@_profile_scoped
def _(rid, params: dict) -> dict:
    from tui_gateway.contracts.chat_provider import ChatDeskDecideParams
    parsed, invalid = _parsed(rid, ChatDeskDecideParams, params)
    if invalid is not None:
        return invalid
    from gateway.desk.runtime import decide_for_owner
    from gateway.desk.service import DecideStatus
    from tui_gateway.desk_wire import item_wire
    reasons = {DecideStatus.NOT_FOUND: "not_found", DecideStatus.FORBIDDEN: "owner_only", DecideStatus.STALE: "stale_revision"}

    def call(home):
        result = decide_for_owner(home, parsed.item_id, parsed.choice.value, parsed.expected_revision)
        item = item_wire(result.item).model_dump(mode="json") if result.item is not None else None
        if result.status is DecideStatus.APPLIED:
            return _ok(rid, {"item": item})
        reason = reasons[result.status]
        return _err(rid, _CHAT_CODES[reason], _CHAT_MESSAGES[reason], data={"reason": reason, "item": item})
    return _desk_run(rid, params, call)


def register(server) -> None:
    bind_module(globals(), server, skip=("_",))
