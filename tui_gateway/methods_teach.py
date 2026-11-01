"""Teach a bot a skill by demonstration: ``bot.teach.*`` JSON-RPC handlers.

``bot.teach.start`` records the owner's browser demonstration while they hold the Bot Desktop lease;
``bot.teach.stop`` ends it and returns the hidden-turn prompt the client submits to the bot's Bot Chat;
``bot.teach.draft`` / ``draft.save`` / ``approve`` / ``discard`` are the owner's review of the draft skill the
bot then writes (it stays disabled until approved). Logic lives in ``tools/bot_desktop/teach*.py``; these are
the profile-scoped doors. ``start`` takes a viewer id and checks it the way ``display.lease.acquire`` does
(minted for THIS connection, ``_foreign_viewer_id`` from ``methods_display``).

Bodies are rebound onto server.py's globals (method_ctx.bind_module) and reference them bare.
"""

import logging

from .method_ctx import HandlerRegistry, bind_module

logger = logging.getLogger(__name__)
_registry = HandlerRegistry()
method = _registry.method
_profile_scoped = _registry.profile_scoped

_TEACH_ERR = 5310


def _teach_failure(rid, exc) -> dict:
    return _err(rid, _TEACH_ERR, str(exc), data={"code": exc.code})


def _teach_call(rid, fn, *args, **kwargs) -> dict:
    from tools.bot_desktop import teach, teach_draft
    try:
        return _ok(rid, fn(*args, **kwargs))
    except (teach.TeachError, teach_draft.DraftError) as exc:
        return _teach_failure(rid, exc)
    except Exception as exc:
        logger.exception("bot.teach failed")
        return _err(rid, _TEACH_ERR, str(exc), data={"code": "internal"})


def _teach_id(params: dict) -> str:
    return str(params.get("teach_id") or "").strip()


@method("bot.teach.status")
@_profile_scoped
def _(rid, params: dict) -> dict:
    from tools.bot_desktop import teach
    return _teach_call(rid, teach.status)


@method("bot.teach.start")
@_profile_scoped
def _(rid, params: dict) -> dict:
    from tools.bot_desktop import teach
    viewer_id = str(params.get("viewer_id") or "").strip()
    if not viewer_id:
        return _err(rid, _TEACH_ERR, "viewer_id required", data={"code": "not_in_control"})
    if (refused := _foreign_viewer_id(rid, viewer_id)) is not None:
        return refused
    return _teach_call(rid, teach.start, viewer_id)


@method("bot.teach.stop")
@_profile_scoped
def _(rid, params: dict) -> dict:
    from tools.bot_desktop import teach
    return _teach_call(rid, teach.stop, discard=bool(params.get("discard")))


@method("bot.teach.prompt")
@_profile_scoped
def _(rid, params: dict) -> dict:
    from tools.bot_desktop import teach_draft
    return _teach_call(rid, lambda: {"prompt": teach_draft.build_prompt(_teach_id(params))})


@method("bot.teach.draft")
@_profile_scoped
def _(rid, params: dict) -> dict:
    from tools.bot_desktop import teach_draft
    return _teach_call(rid, teach_draft.get, _teach_id(params))


@method("bot.teach.draft.save")
@_profile_scoped
def _(rid, params: dict) -> dict:
    from tools.bot_desktop import teach_draft
    return _teach_call(rid, teach_draft.save, _teach_id(params), str(params.get("content") or ""))


@method("bot.teach.approve")
@_profile_scoped
def _(rid, params: dict) -> dict:
    from tools.bot_desktop import teach_draft
    content, reviewed = params.get("content"), params.get("content_hash")
    return _teach_call(rid, teach_draft.approve, _teach_id(params), content if isinstance(content, str) else None,
                       reviewed if isinstance(reviewed, str) else None)


@method("bot.teach.discard")
@_profile_scoped
def _(rid, params: dict) -> dict:
    from tools.bot_desktop import teach_draft
    return _teach_call(rid, teach_draft.discard, _teach_id(params))


def register(server) -> None:
    bind_module(globals(), server, skip=("_",))
