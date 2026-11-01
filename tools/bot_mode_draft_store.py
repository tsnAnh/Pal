import contextlib
import json
import logging
import os
import re
import time
import uuid
from pathlib import Path

from tools.bot_mode_drafts import (
    Outbound, approved_send, card_description, classify_outbound, details_payload, validate_edit,
)
from utils import atomic_json_write

logger = logging.getLogger(__name__)

DEFAULT_TTL_SECONDS = 1800
MAX_PENDING_DRAFTS = 200
_GC_AFTER_EXPIRY_SECONDS = 7 * 24 * 3600
_GC_STAGED_SECONDS = 3600
_PENDING, _CLAIMED, _SENDING, _DISCARDED = "pending", "claimed", "sending", "discarded"
_ID_RE = re.compile(r"^[0-9a-f]{32}$")
REQUEST_ID_PREFIX = "draft:"


class DraftError(Exception):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


def _home(home: str | Path | None) -> Path:
    from hermes_constants import get_hermes_home
    return Path(home) if home else get_hermes_home()


def _dir(home: str | Path | None, state: str, *, create: bool = False) -> Path:
    path = _home(home) / "bot_mode" / "drafts" / state
    if create:
        path.mkdir(parents=True, exist_ok=True, mode=0o700)
    return path


def _ttl_seconds() -> int:
    from hermes_cli.config import load_config_readonly
    raw = (load_config_readonly().get("bot_mode") or {}).get("draft_ttl_seconds", DEFAULT_TTL_SECONDS)
    try:
        return max(0, int(raw))
    except (TypeError, ValueError):
        return DEFAULT_TTL_SECONDS


def _valid_id(draft_id) -> str:
    if not isinstance(draft_id, str) or not _ID_RE.match(draft_id):
        raise DraftError("not_found", "This draft no longer exists.")
    return draft_id


def hold(outbound: Outbound, args: dict, *, origin: str, home: str | Path | None = None) -> dict:
    pending = _dir(home, _PENDING, create=True)
    list_pending(home)
    if sum(1 for _ in pending.glob("*.json")) >= MAX_PENDING_DRAFTS:
        raise DraftError("limit", f"There are too many drafts waiting for the owner ({MAX_PENDING_DRAFTS}). "
                                  "The owner must send or discard some before new ones can be held.")
    now = time.time()
    ttl = _ttl_seconds()
    record = {
        "id": uuid.uuid4().hex, "created_at": now, "expires_at": now + ttl if ttl else None, "origin": origin,
        "tool": outbound.tool, "args": args, "channel": outbound.channel, "recipient": outbound.recipient,
        "subject": outbound.subject, "text": outbound.text, "text_field": outbound.text_field,
    }
    atomic_json_write(pending / f"{record['id']}.json", record, mode=0o600)
    logger.info("held outbound draft %s for %s (%s)", record["id"], outbound.tool, origin)
    return record


def _read(path: Path) -> dict | None:
    try:
        record = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError):
        return None
    return record if isinstance(record, dict) and _ID_RE.match(str(record.get("id", ""))) else None


def _expired(record: dict, now: float) -> bool:
    expires_at = record.get("expires_at")
    return isinstance(expires_at, (int, float)) and now >= expires_at


def list_pending(home: str | Path | None = None) -> list[dict]:
    pending = _dir(home, _PENDING)
    if not pending.is_dir():
        return []
    now = time.time()
    for stale in pending.glob(".*.tmp"):
        with contextlib.suppress(OSError):
            if now - stale.stat().st_mtime > _GC_STAGED_SECONDS:
                stale.unlink()
    records = []
    for path in pending.glob("*.json"):
        record = _read(path)
        if record is None:
            continue
        expires_at = record.get("expires_at")
        if _expired(record, now) and now - expires_at > _GC_AFTER_EXPIRY_SECONDS:
            path.unlink(missing_ok=True)
            continue
        records.append(record)
    return sorted(records, key=lambda record: record.get("created_at", 0))


def _classify(record: dict) -> Outbound | None:
    try:
        return classify_outbound(record["tool"], record["args"])
    except Exception:
        logger.exception("held draft %s could not be classified", record.get("id"))
        return None


def card_payload(record: dict) -> dict:
    expired = _expired(record, time.time())
    outbound = _classify(record)
    sendable = outbound is not None and outbound.viewable and not expired
    description = card_description(outbound) if outbound is not None else (
        f"Send to {record['recipient'] or record['channel']} via {record['channel']}")
    if outbound is not None and not outbound.viewable:
        description += "\nThis message cannot be shown in full, so it can only be discarded."
    return {
        "request_id": REQUEST_ID_PREFIX + record["id"],
        "command": record["text"],
        "description": description,
        "details": details_payload(outbound) if outbound is not None else [],
        "choices": ["once", "deny"] if sendable else ["deny"],
        "allow_permanent": False, "allow_session": False,
        "draft": {
            "kind": "outbound_message", "channel": record["channel"], "recipient": record["recipient"],
            "subject": record["subject"], "text": record["text"], "held": True,
            "editable": record.get("text_field") is not None and sendable,
            "state": "expired" if expired else "pending",
            "expires_at": record.get("expires_at"), "origin": record.get("origin", ""),
        },
    }


def pending_cards(home: str | Path | None = None) -> list[dict]:
    return [card_payload(record) for record in list_pending(home)]


def discard(draft_id: str, home: str | Path | None = None) -> None:
    draft_id = _valid_id(draft_id)
    tombstone = _dir(home, _DISCARDED, create=True) / f"{draft_id}.json"
    for state in (_PENDING, _CLAIMED):
        try:
            os.rename(_dir(home, state) / f"{draft_id}.json", tombstone)
        except FileNotFoundError:
            continue
        atomic_json_write(tombstone, {"id": draft_id, "discarded_at": time.time()}, mode=0o600)
        return
    if (_dir(home, _SENDING) / f"{draft_id}.json").exists():
        raise DraftError("sending", "This draft is already being sent and can no longer be discarded.")
    raise DraftError("not_found", "This draft no longer exists.")


def _claim(draft_id: str, home: str | Path | None) -> tuple[dict, Path]:
    claimed = _dir(home, _CLAIMED, create=True)
    source, target = _dir(home, _PENDING) / f"{draft_id}.json", claimed / f"{draft_id}.json"
    try:
        os.rename(source, target)
    except FileNotFoundError:
        raise DraftError("not_found", "This draft was already sent or discarded.") from None
    record = _read(target)
    if record is None:
        target.unlink(missing_ok=True)
        raise DraftError("corrupt", "This draft could not be read.")
    return record, target


def _begin_delivery(claimed_path: Path, home: str | Path | None) -> Path:
    sending = _dir(home, _SENDING, create=True) / claimed_path.name
    try:
        os.rename(claimed_path, sending)
    except FileNotFoundError:
        raise DraftError("discarded", "This draft was discarded and was not sent.") from None
    return sending


def _release(record: dict, held_path: Path, home: str | Path | None, error: str) -> bool:
    pending = _dir(home, _PENDING, create=True)
    staged = pending / f".{held_path.stem}.{uuid.uuid4().hex}.tmp"
    atomic_json_write(staged, {**record, "last_error": error[:300]}, mode=0o600)
    try:
        held_path.unlink()
    except FileNotFoundError:
        staged.unlink(missing_ok=True)
        return False
    os.replace(staged, pending / held_path.name)
    return True


def _result_error(raw) -> str:
    try:
        parsed = json.loads(raw) if isinstance(raw, str) else raw
    except ValueError:
        return ""
    if not isinstance(parsed, dict):
        return ""
    error = parsed.get("error")
    if isinstance(error, dict):
        error = error.get("message") or error.get("code")
    if error:
        return str(error)
    return "" if parsed.get("success", True) else "the send did not complete"


def _execute(record: dict, args: dict) -> str:
    tool = record["tool"]
    with approved_send():
        if tool == "send_message":
            from tools.send_message_tool import send_message_tool
            return send_message_tool(args)
        import model_tools
        return model_tools.handle_function_call(
            tool, args, task_id=f"draft-{record['id']}", skip_pre_tool_call_hook=True,
            skip_tool_request_middleware=True)


def send(draft_id: str, edited_text=None, home: str | Path | None = None) -> dict:
    draft_id = _valid_id(draft_id)
    record, claimed_path = _claim(draft_id, home)
    if _expired(record, time.time()):
        _release(record, claimed_path, home, "expired")
        raise DraftError("expired", "This draft expired and can no longer be sent.")
    outbound = _classify(record)
    if outbound is None:
        _release(record, claimed_path, home, "not an outbound send")
        raise DraftError("invalid", "This draft can no longer be sent.")
    if not outbound.viewable:
        _release(record, claimed_path, home, "cannot be shown in full")
        raise DraftError("unviewable", "This message cannot be shown in full, so it can only be discarded.")
    args = record["args"]
    if edited_text is not None and edited_text != record["text"]:
        args, reason = validate_edit(outbound, record["args"], edited_text)
        if args is None:
            _release(record, claimed_path, home, reason)
            raise DraftError("invalid_edit", reason[:1].upper() + reason[1:] + ".")
    sending_path = _begin_delivery(claimed_path, home)
    try:
        raw = _execute(record, args)
    except Exception as exc:
        logger.warning("held draft %s send raised %s", draft_id, type(exc).__name__)
        _release(record, sending_path, home, type(exc).__name__)
        raise DraftError("send_failed", "The message could not be sent. It is still waiting here.") from exc
    error = _result_error(raw)
    if error:
        logger.warning("held draft %s send failed", draft_id)
        _release(record, sending_path, home, error)
        raise DraftError("send_failed", "The message could not be sent. It is still waiting here.")
    sending_path.unlink(missing_ok=True)
    return {"status": "sent"}
