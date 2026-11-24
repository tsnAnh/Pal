"""Who may answer a prompt raised in a messaging chat.

A prompt belongs to the user whose message started the turn that raised it. Each pending prompt
records the requester and the profile's ``approvals.approvers`` as its authority, and every surface that
resolves one from a chat event asks :func:`_refusal` through its own refusal helper first.

``approvals.approvers`` defaults to ``["*"]``: any admitted member answers. Narrowing it (``[]``, or a list
of chat user ids) is the opt-in: then only the requester, the listed ids and the platform's admins of the
prompt's chat scope (``allow_admin_from`` in a DM, ``group_allow_admin_from`` in a group, as for slash
commands) answer. Under the default the chat's slash policy fills in: answering a slash-command
confirmation runs that command, so where the scope sets an admin list only someone allowed to run it there
answers. Clarify answers run no command. Host surfaces (CLI, TUI, Desktop, the API server and the session
authority's ``session:approve`` principals) answer as the host and never come through here.

The prompts a chat member can answer for someone else follow the same rule: a slash-command confirmation (:func:`slash_confirm_refusal`) and the agent's
clarify question (:func:`clarify_refusal`), each recording its authority when raised.
"""

from __future__ import annotations

from typing import Any, Iterable, Optional


# Refusal "name" of an entry with no requester recorded; ``refusal_text`` words it as admins-only.
_NO_REQUESTER = "\0no-requester"
# Refusal "name" prefix when the chat's slash policy refused the answer's command (``+ command``).
_ADMIN_ONLY = "\0admin-only:"


def _refusal(authority: dict, actor_id: Any, admin_ids: Any, extra: Any, commands: tuple[str, ...],
             admitted: bool) -> Optional[str]:
    """``None`` when *actor_id* may answer the prompt whose recorded ``authority`` this is, else what the refusal
    names (the answer's admin-only command when the slash policy refused it, else the requester).

    ``approvers`` narrowed (``[]`` or ids): the requester, a listed approver or an admin; that explicit
    approval setting decides. ``approvers: ["*"]`` (the default): anyone the chat's slash policy lets
    run one of *commands*, the answer's own command (``approve`` / ``deny``, or a slash confirm's
    command): everyone admitted where the scope sets no admin list, else admins and
    ``user_allowed_commands``, exactly as if they had typed it. Clarify passes no *commands*.

    The policy comes from ONE source, never a union: a native surface's platform ``extra`` gives the
    policy of the prompt's own chat scope (DM or group, ``slash_access.policy_for_chat_type``); a text or
    relay answer passes the policy of the chat it arrived in (:func:`runner_answer_policy`) as
    *admin_ids*. A bare id list in *admin_ids* names admins with no slash floor. With ``approvers``
    narrowed, an entry with no requester recorded (a turn merged from two senders) is answered by
    approvers and admins only, never by anyone.

    ``admitted=False`` marks an answer whose sender no allowlist admitted (a relayed Discord sender the
    connector never delivered a message from, ``gateway.relay.admitted_authors``): under ``"*"`` the
    sender must then pass the slash floor AND be the requester or an admin, as with ``approvers`` narrowed."""
    from gateway.slash_access import SlashAccessPolicy, _coerce_id_list, policy_for_chat_type

    actor = str(actor_id or "").strip()
    if extra is not None:
        policy = policy_for_chat_type(extra, authority.get("chat_type"))
    elif isinstance(admin_ids, SlashAccessPolicy):
        policy = admin_ids
    else:
        policy = SlashAccessPolicy(False, frozenset(str(a) for a in admin_ids), frozenset())
    approvers = _coerce_id_list(authority.get("approvers"))
    if "*" in approvers:
        if commands and policy.enabled and not any(policy.can_run(actor or None, c) for c in commands):
            return _ADMIN_ONLY + commands[0]
        if admitted:
            return None
    requester = str(authority.get("requester_id") or "")
    if actor and (actor == requester or actor in approvers or actor in policy.admin_user_ids):
        return None
    return str(authority.get("requester_name") or requester or _NO_REQUESTER)


def runner_answer_policy(source: Any):
    """Slash policy of the profile whose bot received *source*: the one the text ``/approve`` uses."""
    from gateway.run import _gateway_runner_ref
    from gateway.slash_access import policy_for_runner_source

    return policy_for_runner_source(_gateway_runner_ref(), source)


def _authority_refusal(authority: Any, actor_id: Any, admin_ids: Any, extra: Any,
                       commands: tuple[str, ...] = (), admitted: bool = True) -> Optional[str]:
    # An empty authority ({}) records no restriction: anyone admitted answers, as on main. An
    # unadmitted sender (``_refusal``'s ``admitted``) needs a recorded requester to match.
    if not authority or not isinstance(authority, dict):
        return None if admitted else _NO_REQUESTER
    return _refusal(authority, actor_id, admin_ids, extra, commands, admitted)


def slash_confirm_refusal(session_key: str, confirm_id: str, actor_id: Any, *, admin_ids: Any = (),
                          extra: Any = None, admitted: bool = True) -> Optional[str]:
    """:func:`_refusal` as a refusal for the slash-command confirmation (``/reload-mcp``) a click or typed
    reply would resolve: the same rule, read from the pending confirm, with the confirmed command as
    the slash floor (answering runs it). Nothing pending (or another confirm id) is never refused: the
    resolver reports it as before."""
    from hermes_cli.commands import resolve_command
    from tools.slash_confirm import get_pending

    pending = get_pending(session_key) or {}
    if pending.get("confirm_id") != confirm_id:
        return None
    command = str(pending.get("command") or "")
    cmd_def = resolve_command(command)
    return _authority_refusal(pending.get("authority"), actor_id, admin_ids, extra,
                              (cmd_def.name if cmd_def else command.lstrip("/"),), admitted)


def clarify_refusal(clarify_id: str, actor_id: Any, *, admin_ids: Any = (),
                    extra: Any = None, admitted: bool = True) -> Optional[str]:
    """:func:`_refusal` as a refusal for the agent's clarify question a tap (choice or "Other") answers."""
    from tools.clarify_gateway import get_pending

    pending = get_pending(clarify_id)
    if pending is None:
        return None
    return _authority_refusal(getattr(pending, "authority", None), actor_id, admin_ids, extra, (), admitted)


def refusal_text(requester: str) -> str:
    from agent.i18n import t

    if requester == _NO_REQUESTER:
        return t("gateway.exec_approval.not_requester_admins_only")
    if requester.startswith(_ADMIN_ONLY):
        return t("gateway.unauthorized.admin_only", command=requester[len(_ADMIN_ONLY):], suffix="").strip()
    return t("gateway.exec_approval.not_requester", requester=requester)


def opener_authority(event: Any) -> Optional[dict]:
    """Who may answer a picker card (``/model``, ``/reasoning``...) or the ``/update`` prompt *event*'s
    sender opened: the opener, or an admin of the chat scope (``allow_admin_from`` /
    ``group_allow_admin_from``), so a member refused an admin-gated command cannot apply an admin's
    open card instead, and nobody else's tap or typed text answers the opener's prompt.
    ``None`` (anyone admitted answers, as before) when the sender is unknown, e.g. a shared observed
    group whose route carries no user, so a card is never left with nobody able to answer it."""
    source = getattr(event, "source", None)
    actor = getattr(event, "user_id", None) or getattr(source, "user_id", None)
    if not actor:
        return None
    return {"requester_id": str(actor),
            "requester_name": str(getattr(event, "user_name", None) or getattr(source, "user_name", None) or actor),
            "chat_type": str(getattr(source, "chat_type", "") or ""), "approvers": []}


def picker_refusal(on_selected: Any, actor_id: Any, *, extra: Any = None) -> Optional[str]:
    """``None`` when *actor_id* may use the picker card whose selection callback is *on_selected*;
    otherwise the opener's name for :func:`refusal_text`. The gateway sets the opener's
    :func:`opener_authority` on the callback as ``prompt_authority``, so every adapter's picker
    state already carries it; a callback without one is never refused. Adapters pass their
    platform ``extra`` block (its admins answer any card of that chat scope)."""
    return _authority_refusal(getattr(on_selected, "prompt_authority", None), actor_id, (), extra)


def update_prompt_refusal(actor_id: Any, *, admin_ids: Iterable[str] = (), extra: Any = None) -> Optional[str]:
    """:func:`picker_refusal` for the pending ``/update`` Yes/No prompt: the authority ``/update``
    recorded in its pending marker. No marker or no authority in it is never refused."""
    import json

    from hermes_constants import get_process_hermes_home  # where /update wrote it (gateway.run._hermes_home)

    for name in (".update_pending.claimed.json", ".update_pending.json"):
        try:
            marker = json.loads((get_process_hermes_home() / name).read_text(encoding="utf-8-sig"))
        except (OSError, ValueError):
            continue
        return _authority_refusal(marker.get("authority") if isinstance(marker, dict) else None, actor_id, admin_ids, extra)
    return None
