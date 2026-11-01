import contextlib
import contextvars
import hashlib
import json
import logging
import re
from dataclasses import dataclass
from itertools import chain
from pathlib import Path

logger = logging.getLogger(__name__)

MAX_TEXT_CHARS = 100_000
MAX_ARGS_CHARS = 300_000
NON_SENDING_SEND_MESSAGE_ACTIONS = frozenset({"list", "react", "unreact"})
DRAFT_KIND = "outbound_message"

_SEND_TOKENS = frozenset({"send", "post", "reply", "forward", "publish", "broadcast", "tweet", "dm"})
_READ_TOKENS = frozenset({"list", "get", "read", "search", "fetch", "find", "count", "delete", "remove"})
_TOKEN_RE = re.compile(r"[A-Z]+(?=[A-Z][a-z])|[A-Z]?[a-z]+|[A-Z]+|\d+")
_TEXT_KEYS = ("body", "message", "text", "content", "markdown_text", "html_body", "plain_text", "html")
_RECIPIENT_KEYS = ("to", "recipient", "recipients", "recipient_email", "email", "channel", "channel_id",
                   "chat_id", "target", "user", "user_id")
_SUBJECT_KEYS = ("subject", "title")
_ATTACHMENT_KEYS = frozenset({
    "attachment", "attachments", "file", "files", "file_path", "file_paths", "filepath", "media", "media_files",
    "image", "images", "document", "documents"})
_ATTACHMENT_NAME_KEYS = ("filename", "file_name", "name", "title")
_ATTACHMENT_SIZE_KEYS = ("size", "size_bytes", "file_size")
_ATTACHMENT_BULK_KEYS = frozenset({"content", "data", "bytes", "base64", "blob", "b64", "body"})
_URL_RE = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*://")
_MCP_PREFIX = "mcp__"
_CONNECTOR_PREFIX = "connectors__"

_approved_send: contextvars.ContextVar[bool] = contextvars.ContextVar("bot_mode_approved_send", default=False)


@contextlib.contextmanager
def approved_send():
    token = _approved_send.set(True)
    try:
        yield
    finally:
        _approved_send.reset(token)


@dataclass(frozen=True)
class Outbound:
    tool: str
    channel: str
    recipient: str
    subject: str
    text: str
    text_field: str | None
    details: tuple[tuple[str, str], ...] = ()
    viewable: bool = True

    @property
    def editable(self) -> bool:
        return self.text_field is not None

    @property
    def pattern_key(self) -> str:
        digest = hashlib.sha256(f"{self.channel}\0{self.recipient}".encode()).hexdigest()[:12]
        return f"outbound_draft:{self.tool}:{digest}"


@dataclass(frozen=True)
class Policy:
    ask: bool


def profile_is_bot_managed(home: str | Path | None = None) -> bool:
    from hermes_constants import get_hermes_home
    from tools.bot_mode_probe import _is_bot_managed
    try:
        return _is_bot_managed(Path(home) if home else get_hermes_home())
    except OSError:
        return False


def policy_for_profile(home: str | Path | None = None) -> Policy | None:
    from hermes_cli.config import load_config_readonly
    managed = profile_is_bot_managed(home)
    setting = (load_config_readonly().get("bot_mode") or {}).get("drafts")
    if setting is None:
        return Policy(ask=True) if managed else None
    if not managed and not setting:
        return None
    return Policy(ask=bool(setting))


def _tokens(slug: str) -> set[str]:
    return {token.lower() for token in _TOKEN_RE.findall(slug)}


def _sends_text(slug: str) -> bool:
    tokens = _tokens(slug)
    if not tokens & _SEND_TOKENS or tokens & _READ_TOKENS:
        return False
    return not ("draft" in tokens and "send" not in tokens)


def _split_tool(tool_name: str) -> tuple[str, str, str] | None:
    for prefix, kind in ((_CONNECTOR_PREFIX, "connector"), (_MCP_PREFIX, "mcp")):
        if tool_name.startswith(prefix):
            _, _, rest = tool_name.partition(prefix)
            channel, _, slug = rest.partition("__")
            return (kind, channel, slug) if channel and slug else None
    return None


def _first_text(args: dict, keys: tuple[str, ...]) -> tuple[str | None, str]:
    for key in keys:
        value = args.get(key)
        if isinstance(value, str) and value.strip():
            return key, value
        if isinstance(value, (list, tuple)) and value and all(isinstance(item, str) for item in value):
            return key, ", ".join(value)
    return None, ""


def _channel_label(channel: str) -> str:
    return channel.replace("_", " ").replace("-", " ").strip().title()


def _human_size(count: int) -> str:
    if count < 1024:
        return f"{count} B"
    size = float(count)
    for unit in ("KB", "MB", "GB"):
        size /= 1024
        if size < 1024 or unit == "GB":
            return f"{size:.1f} {unit}"


def _json_text(value, *, indent: int | None = None) -> str | None:
    try:
        return json.dumps(value, ensure_ascii=False, indent=indent, allow_nan=False)
    except (TypeError, ValueError, RecursionError):
        return None


def _compose_value(value) -> str | None:
    if isinstance(value, str):
        return value
    return _json_text(value, indent=2 if isinstance(value, (dict, list, tuple)) else None)


def _describe_path(path: str) -> str:
    if _URL_RE.match(path):
        return path
    target = Path(path).expanduser()
    try:
        size = _human_size(target.stat().st_size) if target.is_file() else "size unknown"
    except (OSError, ValueError):
        size = "size unknown"
    return f"{target.name or path} ({size}) [{path}]"


def _inline_size(value) -> str | None:
    if isinstance(value, (bytes, bytearray)):
        return f"{_human_size(len(value))} inline"
    if isinstance(value, str):
        return f"{len(value)} characters of inline data"
    return None


def _describe_inline_attachment(item: dict) -> str | None:
    if not all(isinstance(key, str) for key in item):
        return None
    name_key = next((key for key in _ATTACHMENT_NAME_KEYS if isinstance(item.get(key), str) and item[key].strip()), None)
    size_key = next((key for key in _ATTACHMENT_SIZE_KEYS
                     if isinstance(item.get(key), int) and not isinstance(item[key], bool)), None)
    size = _human_size(item[size_key]) if size_key else None
    extras = []
    for key, value in item.items():
        if key in (name_key, size_key):
            continue
        if key in _ATTACHMENT_BULK_KEYS and _inline_size(value) is not None:
            size = size or _inline_size(value)
            continue
        rendered = _compose_value(value)
        if rendered is None:
            return None
        extras.append(f"{key}: {rendered}")
    line = f"{item[name_key] if name_key else 'unnamed'} ({size or 'size unknown'})"
    return f"{line} [{'; '.join(extras)}]" if extras else line


def _describe_attachments(value) -> str | None:
    lines = []
    for item in value if isinstance(value, (list, tuple)) else [value]:
        if isinstance(item, str):
            line = _describe_path(item)
        elif isinstance(item, dict):
            line = _describe_inline_attachment(item)
        else:
            line = _compose_value(item)
        if line is None:
            return None
        lines.append(line)
    return "\n".join(lines)


def _is_attachment_key(key) -> bool:
    return isinstance(key, str) and key.lower() in _ATTACHMENT_KEYS


def _detail_items(args: dict, hidden: set) -> tuple[tuple[tuple[str, str], ...], bool]:
    items, viewable = [], True
    for key, value in args.items():
        if key in hidden:
            continue
        rendered = _describe_attachments(value) if _is_attachment_key(key) else _compose_value(value)
        if rendered is None or not isinstance(key, str):
            viewable = False
            rendered = rendered if rendered is not None else "(cannot be shown in full)"
        items.append((str(key), rendered))
    return tuple(items), viewable


def _assemble(tool_name: str, channel: str, args: dict, *, text: str, text_field: str | None, recipient: str,
              recipient_key: str | None, subject: str, subject_key: str | None) -> Outbound:
    if text_field is None:
        whole = _json_text(args, indent=2)
        details, viewable = _detail_items(args, {key for key in args if not _is_attachment_key(key)})
        text = whole if whole is not None else json.dumps(args, ensure_ascii=False, indent=2, default=repr)
        return Outbound(tool_name, channel, recipient, subject, text, None, details, viewable and whole is not None)
    details, viewable = _detail_items(args, {text_field, recipient_key, subject_key} - {None})
    return Outbound(tool_name, channel, recipient, subject, text, text_field, details, viewable)


def _is_non_sending_send_message(args: dict) -> bool:
    action = args.get("action", "send")
    return isinstance(action, str) and action in NON_SENDING_SEND_MESSAGE_ACTIONS


def classify_outbound(tool_name: str, args: dict) -> Outbound | None:
    if tool_name == "send_message":
        if _is_non_sending_send_message(args):
            return None
        raw_target = args.get("target")
        target = str(raw_target or "").strip()
        field, text = _first_text(args, ("message",))
        return _assemble(tool_name, _channel_label(target.partition(":")[0]), args, text=text, text_field=field,
                         recipient=target, recipient_key="target" if isinstance(raw_target, str) else None,
                         subject="", subject_key=None)
    split = _split_tool(tool_name)
    if split is None or not _sends_text(split[2]):
        return None
    field, text = _first_text(args, _TEXT_KEYS)
    recipient_key, recipient = _first_text(args, _RECIPIENT_KEYS)
    subject_key, subject = _first_text(args, _SUBJECT_KEYS)
    return _assemble(tool_name, _channel_label(split[1]), args, text=text, text_field=field, recipient=recipient,
                     recipient_key=recipient_key, subject=subject, subject_key=subject_key)


def looks_outbound(tool_name) -> bool:
    if not isinstance(tool_name, str):
        return False
    if tool_name == "send_message":
        return True
    split = _split_tool(tool_name)
    return split is not None and _sends_text(split[2])


def _strings(value):
    stack, seen = [value], set()
    while stack:
        item = stack.pop()
        if isinstance(item, str):
            yield item
        elif isinstance(item, (dict, list, tuple, set, frozenset)):
            if id(item) in seen:
                continue
            seen.add(id(item))
            stack.extend(chain.from_iterable(item.items()) if isinstance(item, dict) else item)


def _carries_secret(*parts: str) -> bool:
    from agent.redact import redact_sensitive_text
    return any(part and redact_sensitive_text(part, force=True) != part for part in parts)


def validate_edit(outbound: Outbound, args: dict, edited_text) -> tuple[dict | None, str]:
    if outbound.text_field is None:
        return None, "this message cannot be edited"
    if not isinstance(edited_text, str) or not edited_text.strip():
        return None, "the edited message is empty"
    if len(edited_text) > MAX_TEXT_CHARS or "\x00" in edited_text:
        return None, "the edited message is too long or contains invalid characters"
    if _carries_secret(edited_text):
        return None, "the edited message contains what looks like a credential"
    from agent.message_sanitization import _sanitize_surrogates
    new_args = {**args, outbound.text_field: _sanitize_surrogates(edited_text)}
    again = classify_outbound(outbound.tool, new_args)
    if (again is None or again.recipient != outbound.recipient or again.channel != outbound.channel
            or again.details != outbound.details):
        return None, "the edit changed where the message goes"
    return new_args, ""


def _held_message(draft_id: str, reason: str) -> str:
    return (f"BLOCKED: {reason} The message was NOT sent. A draft is waiting in the owner's Bot Chat "
            f"(draft {draft_id}); the owner decides whether to send it. Do NOT retry it, do NOT rephrase it, "
            "and do NOT deliver the same message through another tool or route.")


def _hold(outbound: Outbound, args: dict, origin: str, reason: str) -> tuple[str, None]:
    from tools import bot_mode_draft_store
    try:
        record = bot_mode_draft_store.hold(outbound, args, origin=origin)
    except bot_mode_draft_store.DraftError as exc:
        if exc.code != "limit":
            raise
        return (f"BLOCKED: {exc.message} The message was NOT sent. Do NOT retry it or deliver it through "
                "another route."), None
    except (OSError, ValueError, TypeError):
        logger.exception("could not hold outbound draft for %s", outbound.tool)
        return ("BLOCKED: The draft could not be saved, so the message was NOT sent. Do NOT retry it or "
                "deliver it through another route."), None
    return _held_message(record["id"], reason), None


def _inline_capable(approval) -> bool:
    from tools import approval_context
    if approval_context.is_bot_chat_turn():
        return True
    callback, is_cli, _is_gateway, _is_ask = approval._presence()
    return bool(is_cli and callback is not None)


def _card(outbound: Outbound) -> dict:
    return {
        "kind": DRAFT_KIND, "channel": outbound.channel, "recipient": outbound.recipient,
        "subject": outbound.subject, "text": outbound.text, "editable": outbound.editable, "held": False,
    }


def details_payload(outbound: Outbound) -> list[dict]:
    return [{"name": name, "value": value} for name, value in outbound.details]


def card_description(outbound: Outbound) -> str:
    header = f"Send to {outbound.recipient or outbound.channel} via {outbound.channel}"
    return "\n".join([header, *(f"{name}: {value}" for name, value in outbound.details)])


def _ask_owner(outbound: Outbound, args: dict) -> tuple[str | None, dict | None]:
    from tools import approval
    result = approval.request_draft_approval(
        text=outbound.text, description=card_description(outbound), pattern_key=outbound.pattern_key,
        draft=_card(outbound), details=details_payload(outbound))
    if not result.get("approved"):
        if result.get("outcome") == "timeout":
            return _hold(outbound, args, "timeout", "The owner did not answer in time.")
        return str(result.get("message") or "BLOCKED: the draft was not approved; it was NOT sent."), None
    edited = result.get("edited_text")
    if edited is None or edited == outbound.text:
        return None, None
    new_args, reason = validate_edit(outbound, args, edited)
    if new_args is None:
        return f"BLOCKED: {reason}. The message was NOT sent. Do NOT retry it.", None
    return None, new_args


def _review(outbound: Outbound, args: dict) -> tuple[str | None, dict | None]:
    policy = policy_for_profile()
    if policy is None:
        return None, None
    if len(outbound.text) > MAX_TEXT_CHARS or sum(len(part) for part in _strings(args)) > MAX_ARGS_CHARS:
        return "BLOCKED: This message is too long to send. It was NOT sent. Shorten it.", None
    if _carries_secret(*_strings(args), outbound.text, outbound.subject):
        return ("BLOCKED: This message contains what looks like a credential, so it was NOT sent and no "
                "draft was made. Remove the secret and do not retry with it."), None
    from tools import approval, approval_context
    if approval_context._no_user_can_answer():
        return _hold(outbound, args, "unattended", "Nobody is present to approve outbound messages in this run.")
    if not policy.ask:
        return None, None
    if not outbound.viewable:
        return _hold(outbound, args, "unviewable",
                     "Part of this message cannot be shown in full, so it can only be discarded.")
    if not _inline_capable(approval):
        return _hold(outbound, args, "elsewhere", "Drafts are reviewed in the bot's own Bot Chat.")
    return _ask_owner(outbound, args)


_REVIEW_FAILED = "BLOCKED: The outbound draft review failed, so the message was NOT sent. Do NOT retry it."


def blocked_on_failure(tool_name) -> str | None:
    if not looks_outbound(tool_name):
        return None
    try:
        if policy_for_profile() is None:
            return None
    except Exception:
        logger.exception("could not read the draft policy while failing closed for %s", tool_name)
    return _REVIEW_FAILED


def review_after_hooks(tool_name: str, args, load_details, resolve_block) -> tuple[str | None, dict | None]:
    try:
        details = load_details()
        block = resolve_block(details)
    except Exception:
        logger.exception("pre_tool_call resolution failed for %s", tool_name)
        failed = blocked_on_failure(tool_name)
        if failed is None:
            raise
        return failed, None
    modified_args = details.modified_args
    if block is not None:
        return block, modified_args
    draft_block, edited_args = review_outbound(tool_name, modified_args if modified_args is not None else args)
    return draft_block, edited_args if edited_args is not None else modified_args


def review_outbound(tool_name: str, args) -> tuple[str | None, dict | None]:
    if _approved_send.get():
        return None, None
    if not isinstance(args, dict):
        return blocked_on_failure(tool_name), None
    try:
        outbound = classify_outbound(tool_name, args)
    except Exception:
        logger.exception("outbound classification failed for %s", tool_name)
        return blocked_on_failure(tool_name), None
    if outbound is None:
        return None, None
    try:
        return _review(outbound, args)
    except Exception:
        logger.exception("outbound draft review failed for %s", tool_name)
        return _REVIEW_FAILED, None
