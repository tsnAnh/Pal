from __future__ import annotations

import re
from collections.abc import Iterator, Mapping
from dataclasses import dataclass
from enum import Enum
from typing import Any, Optional

from cron.execution_identity import current_cron_job
from cron.job_args import _normalize_deliver_param
from cron.job_provenance import set_by_owner, written_by_owner
from tools.approval_context import _is_cron_approval_context
from tools.bot_mode_drafts import _carries_secret, _strings, classify_outbound, flatten_args

_SIGILS = ("#", "@")
_MIN_BARE_ID_CHARS = 6
_MIN_BARE_NAME_CHARS = 12
_PROMPT_SEPARATORS = re.compile(r"""[\s,;:()\[\]{}<>"'`*|=“”‘’«»]+""")
_LIST_SEPARATORS = re.compile(r"[,;]")
_THREADED_REF = re.compile(r"(.+?):(\d+(?:\.\d+)?)")
_SEND_MESSAGE_ARGS = frozenset({"action", "target", "message"})


class _Role(Enum):
    DESTINATION = "destination"
    THREAD = "thread"
    CONTENT = "content"


_ARG_ROLES: dict[str, _Role] = {
    **dict.fromkeys((
        "to", "cc", "bcc", "recipient", "recipients", "recipientemail", "email", "channel", "channelid", "chat",
        "chatid", "target", "user", "userid", "roomid", "conversationid", "freelancerid"), _Role.DESTINATION),
    **dict.fromkeys(("thread", "threadid", "threadts", "messagethreadid"), _Role.THREAD),
    **dict.fromkeys((
        "body", "message", "text", "content", "markdowntext", "htmlbody", "plaintext", "html", "subject", "title",
        "blocks", "mrkdwn", "parsemode", "unfurllinks", "unfurlmedia", "action", "attachment", "attachments",
        "file", "files", "filepath", "filepaths", "fileattachments", "media", "mediafiles", "image", "images",
        "document", "documents"), _Role.CONTENT),
}


@dataclass(frozen=True)
class SendCall:
    platform: str
    destinations: tuple[frozenset[str], ...]
    thread: str
    texts: tuple[str, ...]


def _chat_and_thread(ref: str) -> tuple[str, str]:
    threaded = _THREADED_REF.fullmatch(ref)
    return (threaded[1], threaded[2]) if threaded else (ref, "")


def _values(value: Any) -> Optional[list[str]]:
    items = value if isinstance(value, (list, tuple)) else [value]
    if not all(isinstance(item, (str, int)) and not isinstance(item, bool) for item in items):
        return None
    return [part.strip() for item in items for part in _LIST_SEPARATORS.split(str(item)) if part.strip()]


def _addresses(args: Mapping) -> Optional[tuple[list[str], list[str]]]:
    destinations: list[str] = []
    threads: list[str] = []
    for key, value in args.items():
        if value is None or value == "" or value == []:
            continue
        role = _ARG_ROLES.get(str(key).lower().replace("_", "").replace("-", ""))
        if role is _Role.CONTENT:
            continue
        values = _values(value)
        if role is None or values is None:
            return None
        (destinations if role is _Role.DESTINATION else threads).extend(values)
    return destinations, threads


def send_call(tool_name: str, args: Mapping) -> Optional[SendCall]:
    call_args = dict(args)
    outbound = classify_outbound(tool_name, call_args)
    if outbound is None:
        return None
    texts = tuple(_strings(call_args))
    if tool_name == "send_message":
        platform, _, ref = str(call_args.get("target") or "").strip().partition(":")
        if not platform or set(call_args) - _SEND_MESSAGE_ARGS:
            return None
        chat, thread = _chat_and_thread(ref)
        return SendCall(platform.casefold(), (frozenset({chat}),), thread, texts)
    found = _addresses(flatten_args(call_args))
    if found is None or len(set(found[1])) > 1:
        return None
    destinations, threads = found if found[0] else (found[1], [])
    if not destinations:
        return None
    return SendCall(outbound.channel.casefold(), tuple(frozenset({place}) for place in destinations),
                    threads[0] if threads else "", texts)


def _split_sigil(value: str) -> tuple[str, str]:
    folded = value.strip().casefold()
    return (folded[0], folded[1:]) if folded.startswith(_SIGILS) else ("", folded)


def _same(written: str, spelled: str) -> bool:
    (written_sigil, written_body), (sigil, body) = _split_sigil(written), _split_sigil(spelled)
    return written_body == body and (not written_sigil or not sigil or written_sigil == sigil)


def _reads_as_address(token: str) -> bool:
    # Prose holds words like ``general`` and ``follow-up``, so a bare one never names a channel.
    sigil, body = _split_sigil(token)
    if sigil or "@" in body:
        return True
    if any(char.isdigit() for char in body):
        return len(body.lstrip("+-")) >= _MIN_BARE_ID_CHARS
    return len(body) >= _MIN_BARE_NAME_CHARS and any(char in "-_" for char in body)


def _deliver_targets(job: Mapping) -> Iterator[tuple[str, str, str]]:
    if not set_by_owner(job, "deliver"):
        return
    for entry in str(_normalize_deliver_param(job.get("deliver")) or "").split(","):
        if entry.strip().casefold() == "origin":
            origin = (job.get("origin") if set_by_owner(job, "origin") else None) or {}
            yield (str(origin.get("platform") or "").casefold(), str(origin.get("chat_id") or ""),
                   str(origin.get("thread_id") or ""))
        else:
            platform, _, ref = entry.strip().partition(":")
            yield (platform.casefold(), *_chat_and_thread(ref))


def _job_names(job: Mapping, call: SendCall, spellings: frozenset[str]) -> bool:
    tokens = (token.rstrip(".!?…") for token in _PROMPT_SEPARATORS.split(str(job.get("prompt") or "")))
    if any(_reads_as_address(token) and _same(token, spelled) for token in tokens for spelled in spellings):
        return True
    return any(
        platform == call.platform and thread in ("", call.thread) and any(_same(chat, spelled) for spelled in spellings)
        for platform, chat, thread in _deliver_targets(job))


def routine_send_allowed(call: Optional[SendCall], job: Optional[Mapping]) -> Optional[str]:
    if call is None or job is None or not call.destinations or not written_by_owner(job):
        return None
    if _carries_secret(*call.texts):
        return None
    if not all(_job_names(job, call, spellings) for spellings in call.destinations):
        return None
    return f"routine send approved by job {job['id']}"


def current_routine() -> Optional[Mapping]:
    return current_cron_job() if _is_cron_approval_context() else None


def reason_for_tool(tool_name: str, args: Mapping) -> Optional[str]:
    job = current_routine()
    return None if job is None else routine_send_allowed(send_call(tool_name, args), job)
