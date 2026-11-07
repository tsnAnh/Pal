from __future__ import annotations

import logging
import sqlite3
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from enum import StrEnum
from pathlib import Path

from gateway import device_registry, push_apns
from gateway.device_presence import anyone_attentive, served_authorities
from hermes_state_keys import CRON_PRINCIPAL_ID

logger = logging.getLogger(__name__)

TITLE_LIMIT = 60
BODY_LIMIT = 140
WORKERS = 2


class Kind(StrEnum):
    FINISHED = "finished"
    FAILED = "failed"
    APPROVAL = "approval"
    CLARIFY = "clarify"


BODIES = {Kind.FAILED: "Stopped with a problem", Kind.APPROVAL: "is waiting for you",
          Kind.CLARIFY: "is waiting for you"}
COMPLETION_KINDS = {"complete": Kind.FINISHED, "error": Kind.FAILED}


@dataclass(frozen=True, slots=True)
class Notice:
    kind: Kind
    session_id: str
    claim_key: str
    reply: str = ""


_executor_lock = threading.Lock()
_executor: ThreadPoolExecutor | None = None
_noted_unconfigured = False


def _submit(authority, notice: Notice) -> None:
    global _executor
    with _executor_lock:
        if _executor is None:
            _executor = ThreadPoolExecutor(max_workers=WORKERS, thread_name_prefix="push-notify")
        executor = _executor
    try:
        executor.submit(_run, authority, notice)
    except RuntimeError:
        logger.debug("Push notifications are shutting down; dropped a %s event", notice.kind.value)


def _run(authority, notice: Notice) -> None:
    try:
        deliver(authority, notice, time.time())
    except Exception:
        logger.warning("Push notification for a %s event failed", notice.kind.value, exc_info=True)


def _field(row, name: str):
    try:
        return row[name]
    except (KeyError, IndexError, TypeError):
        return None


def turn_finished(authority, session_id: str, row, complete: dict) -> None:
    kind = COMPLETION_KINDS.get(complete.get("status"))
    admission_id = _field(row, "admission_id")
    if kind is None or not admission_id or _field(row, "principal_id") == CRON_PRINCIPAL_ID:
        return
    text = complete.get("text")
    _submit(authority, Notice(kind, session_id, f"{authority.profile_id}:{session_id}:turn:{admission_id}",
                              text if isinstance(text, str) else ""))


def waiting_on_user(authority, session_id: str, prompt_id: str, kind: Kind) -> None:
    _submit(authority, Notice(kind, session_id, f"{authority.profile_id}:{session_id}:{kind.value}:{prompt_id}"))


def notifications_flag(cfg) -> bool:
    from utils import is_truthy_value
    section = cfg.get("bot_mode") if isinstance(cfg, dict) else None
    return isinstance(section, dict) and is_truthy_value(section.get("notifications", False))


def notifications_enabled(authority) -> bool:
    from gateway.session_authorities import owner_scope
    from hermes_cli.config_effective import load_user_config_effective
    home = Path(str(authority.profile_id))
    if not home.is_absolute() or not home.is_dir():
        return False
    with owner_scope(authority):
        return notifications_flag(load_user_config_effective(home / "config.yaml"))


def _bot_identity(authority) -> tuple[str, str]:
    from hermes_cli.profiles import read_profile_meta
    from hermes_constants import profile_name_for_home
    home = Path(str(authority.profile_id))
    profile = profile_name_for_home(home) or "default"
    meta = read_profile_meta(home)
    name = meta["bot_title"] or meta["display_name"] or ("Hermes" if profile == "default" else profile)
    return profile, name


def _first_line(text: str) -> str:
    for line in text.splitlines():
        collapsed = " ".join(line.split())
        if collapsed:
            return collapsed if len(collapsed) <= BODY_LIMIT else collapsed[:BODY_LIMIT - 1].rstrip() + "…"
    return ""


def _payload(notice: Notice, profile: str, name: str) -> dict:
    body = BODIES.get(notice.kind) or _first_line(notice.reply) or "Finished"
    alert = {"title": name[:TITLE_LIMIT], "body": body}
    return {"aps": {"alert": alert, "sound": "default", "thread-id": profile},
            "profile": profile, "session_id": notice.session_id}


def _note_unconfigured() -> None:
    global _noted_unconfigured
    if not _noted_unconfigured:
        _noted_unconfigured = True
        logger.info("Push notifications are not sent: set push.apns.key_id and push.apns.team_id in config.yaml "
                    "and %s or %s in .env", push_apns.KEY_ENV, push_apns.KEY_PATH_ENV)


def deliver(authority, notice: Notice, now: float) -> int:
    if not notifications_enabled(authority):
        return 0
    if anyone_attentive(served_authorities(authority), now):
        return 0
    root = device_registry.install_root(authority.profile_id)
    config = push_apns.load_config(root)
    if config is None:
        _note_unconfigured()
        return 0
    targets = device_registry.push_targets(root)
    if not targets:
        return 0
    try:
        client = push_apns.shared_client(config)
    except push_apns.ApnsUnavailable:
        return 0
    if not device_registry.claim_push(root, notice.claim_key, now):
        return 0
    profile, name = _bot_identity(authority)
    payload = _payload(notice, profile, name)
    delivered = 0
    for target in targets:
        outcome = client.send(target, payload)
        if outcome is push_apns.Outcome.TOKEN_DEAD:
            try:
                device_registry.drop_push_token(root, target.token)
            except (sqlite3.Error, OSError):
                logger.warning("Could not drop the dead push token of device %s", target.device_id)
        delivered += outcome is push_apns.Outcome.DELIVERED
    return delivered
