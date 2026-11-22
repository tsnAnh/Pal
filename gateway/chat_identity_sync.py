from __future__ import annotations

import logging
import threading
from pathlib import Path

from agent.memory_provider import spawn_context_thread
from gateway.chat_install_store import ChatInstallStore

logger = logging.getLogger(__name__)

_lock = threading.Lock()
_running: set[str] = set()
_again: set[str] = set()


def _describe(exc: Exception) -> str:
    reason = getattr(exc, "reason", None)
    return reason.value if reason is not None else type(exc).__name__


def _push(bot: str, home: Path) -> None:
    from gateway.chat_install_runtime import bot_profile_scope, build_service
    store = ChatInstallStore(home)
    pending = store.pending_identity(bot)
    if not pending:
        return
    with bot_profile_scope(bot):
        service = build_service(home)
        for installation, marked in pending:
            state = store.state_for_installation(installation.id)
            if state is not None:
                try:
                    service.update_identity(bot, installation.provider_id, state.workspace)
                except Exception as exc:  # health: allow BLE001 -- provider errors carry provider text, so only the exception type is logged; the flag stays and the next connect or change retries
                    logger.warning("chat identity sync failed provider=%s error=%s", installation.provider_id,
                                   _describe(exc))
                    continue
            store.clear_identity_pending(installation.id, marked)


def _run(bot: str, home: Path) -> None:
    try:
        while True:
            try:
                _push(bot, home)
            except Exception as exc:  # health: allow BLE001 -- the worker must reach its exit check, and provider text is never logged
                logger.warning("chat identity sync could not run error=%s", type(exc).__name__)
            with _lock:
                if bot not in _again:
                    _running.discard(bot)
                    return
                _again.discard(bot)
    except BaseException:
        with _lock:
            _running.discard(bot)
            _again.discard(bot)
        raise


def _start(bot: str, home: Path) -> None:
    with _lock:
        if bot in _running:
            _again.add(bot)
            return
        _running.add(bot)
    try:
        spawn_context_thread(_run, name=f"chat-identity-sync-{bot}", args=(bot, home)).start()
    except BaseException:
        with _lock:
            _running.discard(bot)
        raise


def schedule_identity_sync(bot: str, home: Path) -> None:
    try:
        store = ChatInstallStore(home)
        installations = store.active_installations(bot)
        for installation in installations:
            store.mark_identity_pending(installation.id)
        if installations:
            _start(bot, home)
    except Exception as exc:  # health: allow BLE001 -- an identity push must never fail the change that triggered it, and provider text is never logged
        logger.warning("chat identity sync could not be scheduled error=%s", type(exc).__name__)


def retry_pending_identity(bot: str, home: Path) -> None:
    try:
        _start(bot, home)
    except Exception as exc:  # health: allow BLE001 -- a retry on connect must never stop the adapter, and provider text is never logged
        logger.warning("chat identity retry could not start error=%s", type(exc).__name__)
