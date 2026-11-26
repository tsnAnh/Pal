from __future__ import annotations

import logging
import uuid
from collections.abc import Callable
from dataclasses import dataclass, replace
from datetime import UTC, datetime
from typing import Any, Optional

from tools.registry import tool_error

logger = logging.getLogger(__name__)

REPORT_ALIAS = "report"
_UNCERTAIN_SLACK_ERRORS = frozenset({"network_failure"})
_WAITING_NOTE = ("Their reply will arrive in this conversation as a new message. End your turn now and tell "
                 "whoever asked that you are waiting for the answer.")
_PENDING_NOTE = ("Your owner was asked to approve this message and it has NOT been sent. Tell whoever asked that "
                 "you are waiting for the owner's approval; the outcome will arrive in this conversation.")


@dataclass(frozen=True)
class WaitRequest:
    requested: bool
    minutes: Optional[int]


def wait_request(args: dict) -> WaitRequest:
    return WaitRequest(args.get("wait_for_reply") is True, args.get("wait_minutes") if args.get("wait_for_reply") is True
                       else None)


def call_item_id() -> str:
    from gateway.desk import item_id_for_call
    from tools import approval_context as ctx
    ids = (ctx.get_current_approval_session_id(), ctx.get_current_turn_id(), ctx.get_current_tool_call_id())
    return item_id_for_call(*ids) if all(ids) else "dk_" + uuid.uuid4().hex[:16]


def _iso(timestamp: float) -> str:
    return datetime.fromtimestamp(timestamp, UTC).strftime("%Y-%m-%dT%H:%MZ")


def _spent_grant(tool: str, args: dict) -> bool:
    from tools.tainted_turn_gate import spend_call_grant
    return spend_call_grant(tool, args)


def _owner_only_refusal() -> str:
    return tool_error("That is your owner. Ask them in this conversation instead of waiting for a Slack reply.",
                      code="use_this_chat")


def _request_owner(desk: Any, contact: Any, to: Any, text: str, label: str, wait: WaitRequest) -> dict:
    from gateway.desk.ticker import nudge_ticker
    item = desk.request_send(item_id=call_item_id(), origin=desk.origin_of_turn(), contact=contact, to=to, text=text,
                             label=label, wait_for_reply=wait.requested, wait_minutes=wait.minutes)
    nudge_ticker()
    return {"sent": False, "pending_owner_approval": True, "recipient": label, "note": _PENDING_NOTE,
            "request": item.id}


def _send_tracked(desk: Any, contact: Any, to: Any, text: str, wait: WaitRequest,
                  post: Callable[[], dict], shown: dict) -> dict | str:
    from gateway.chat_slack.api import SlackSetupError
    from gateway.desk.owner import clamped_wait_minutes, desk_settings
    reservation = desk.begin_ask(
        item_id=call_item_id(), origin=desk.origin_of_turn(), contact=contact, target=to, question=text,
        wait_minutes=clamped_wait_minutes(wait.minutes, desk_settings()))
    item = reservation.item
    if not reservation.fresh:
        state = item.state.value
        if state == "open":
            return {"sent": True, **shown, "waiting": {"ask_id": item.id, "until": _iso(item.expires_at)},
                    "note": _WAITING_NOTE}
        return tool_error("This message may or may not have reached them, so it was not sent again. Check before "
                          "asking again.", code="ask_unconfirmed")
    try:
        posted = post()
    except SlackSetupError as exc:
        if exc.slack_error not in _UNCERTAIN_SLACK_ERRORS:
            from gateway.desk import ItemState
            desk.store.transition(item.id, ItemState.POSTING, ItemState.FAILED, revision=item.revision,
                                  wake_origin=False)
        raise
    anchor = to.thread_ts or posted.get("ts")
    if anchor:
        desk.open_ask(item, str(anchor))
    return {"sent": True, **shown, **{k: v for k, v in posted.items() if v}, "waiting": {
        "ask_id": item.id, "until": _iso(item.expires_at)}, "note": _WAITING_NOTE}


def deliver(
    tool: str, args: dict, *, to: Any, text: str, label: str, shown: dict, wait: WaitRequest,
    post: Callable[[], dict], legacy: Callable[[], dict | str], spellings: tuple[str, ...],
) -> dict | str:
    from gateway.desk import Outbound, outbound_decision
    from gateway.desk.service import Desk
    from gateway.desk.owner import owner_contact, turn_facts
    from tools import routine_send
    call = routine_send.SendCall("slack", (frozenset(filter(None, spellings)),), to.thread_ts or "", (text,))

    def routine_approves() -> bool:
        # A waiting post opens a reply path to ``reply_from``, which no routine names.
        job = None if wait.requested else routine_send.current_routine()
        reason = routine_send.routine_send_allowed(call, job)
        if reason:
            logger.info(reason)
        return reason is not None

    facts = turn_facts("slack")
    if facts is None:
        result = {"sent": True, **shown, **post()} if routine_approves() else legacy()
        if wait.requested and isinstance(result, dict):
            return {**result, "waiting": False, "note": "Replies to this message will not wake this conversation."}
        return result
    contact = owner_contact("slack", to.scope_id)
    if wait.requested and to.user_id == facts.owner_id:
        return _owner_only_refusal()
    desk = Desk.in_turn()
    judged = to if to.direct else replace(to, user_id=None)
    if (not _spent_grant(tool, args) and outbound_decision(facts, judged) is Outbound.ASK_OWNER
            and not routine_approves()):
        return _request_owner(desk, contact, to, text, label, wait)
    if wait.requested:
        return _send_tracked(desk, contact, to, text, wait, post, shown)
    return {"sent": True, **shown, **post()}


def report_destination(call: Callable[..., dict], team_id: str) -> Optional[tuple[Any, str]]:
    from gateway.desk import Recipient
    from gateway.desk.owner import owner_contact
    contact = owner_contact("slack", team_id)
    if contact is None:
        return None
    channel = contact.conversation_id or (call("conversations.open", {"users": contact.user_id}).get("channel") or {}).get("id")
    if not channel:
        return None
    return Recipient("slack", team_id, contact.user_id, str(channel), None, True), "your direct messages"


def post_report(call: Callable[..., dict], args: dict, team_id: str) -> dict | str:
    from gateway.desk.owner import turn_facts
    destination = report_destination(call, team_id)
    if destination is None:
        return tool_error("No place for reports is set up yet, so nothing was sent.", code="report_not_configured")
    to, label = destination
    if args.get("wait_for_reply") is True:
        return _owner_only_refusal()
    facts = turn_facts("slack")
    if facts is not None and facts.audience.value != "owner":
        return tool_error("Only the owner's own conversation can send reports.", code="approval_required")
    body = call("chat.postMessage", {"channel": to.conversation_id, "text": str(args["text"])})
    return {"sent": True, "channel": label, "ts": body.get("ts")}
