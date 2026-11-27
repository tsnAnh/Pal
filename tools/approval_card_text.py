"""What the owner reads when a send needs a yes: the message bubble and the card's words.

The bubble is written for a person: who and where, then the whole message as paragraphs, then attachment names.
No tool name, no argument dump, no instruction aimed at the model. The card's question and option labels follow the
language of the owner's latest message (Vietnamese or English), carried to the apps as ``language`` and ``labels``
beside the ``question`` the apps already show.
"""

from __future__ import annotations

from collections.abc import Iterable, Mapping

_STRINGS: dict[str, dict[str, str]] = {
    "en": {"question": "Send this message?", "send": "Send", "edit": "Edit", "cancel": "Cancel",
           "note": "Nothing is sent until you choose Send.", "to": "To", "via": "via", "on": "on",
           "subject": "Subject", "attachments": "Attachments", "message": "Message",
           "rule_saved": "From now on {bot} sends to {destination} via {channel} without asking. To undo this, remove "
                         "it from {bot}'s always-allow list.",
           "rule_failed": "{bot} could not save that, and will ask again before sending to {destination} via "
                          "{channel}."},
    "vi": {"question": "Gửi tin nhắn này?", "send": "Gửi", "edit": "Sửa", "cancel": "Hủy",
           "note": "Chỉ gửi khi bạn chọn Gửi.", "to": "Gửi tới", "via": "qua", "on": "trên",
           "subject": "Chủ đề", "attachments": "Tệp đính kèm", "message": "Tin nhắn",
           "rule_saved": "Từ giờ {bot} gửi tới {destination} qua {channel} mà không hỏi lại. Muốn đổi, hãy xóa mục này "
                         "trong danh sách luôn cho phép của {bot}.",
           "rule_failed": "{bot} chưa lưu được, nên lần sau vẫn hỏi trước khi gửi tới {destination} qua {channel}."},
}
_LABEL_KEYS = ("send", "edit", "cancel", "note")
_VIETNAMESE_ONLY = frozenset("đĐơƠưƯ")
_VIETNAMESE_MIN_SHARE = 0.03


def _is_vietnamese_letter(char: str) -> bool:
    return char in _VIETNAMESE_ONLY or "Ạ" <= char <= "ỹ"


def detect_language(text: str) -> str:
    """``vi`` when enough of the letters are ones only Vietnamese uses, else ``en``. Short or unmarked text is
    English: a wrong guess must never put an English reader in front of Vietnamese buttons."""
    letters = [char for char in text if char.isalpha()]
    marked = sum(1 for char in letters if _is_vietnamese_letter(char))
    return "vi" if marked and marked / len(letters) >= _VIETNAMESE_MIN_SHARE else "en"


def owner_language() -> str:
    """Language of the owner's latest message of the running turn; English when no human typed it."""
    from gateway.session_context import current_turn_event
    event = current_turn_event()
    text = getattr(event, "text", "")
    if event is None or getattr(event, "internal", False) or not isinstance(text, str):
        return "en"
    return detect_language(text)


def strings(language: str) -> dict[str, str]:
    return _STRINGS.get(language, _STRINGS["en"])


def card_fields(language: str) -> dict:
    words = strings(language)
    return {"question": words["question"], "language": language if language in _STRINGS else "en",
            "labels": {key: words[key] for key in _LABEL_KEYS}}


def rule_line(language: str, bot: str, destination: str, channel: str, *, saved: bool = True) -> str:
    template = strings(language)["rule_saved" if saved else "rule_failed"]
    return template.format(bot=bot, destination=destination, channel=channel)


def attachment_names(lines: Iterable[str]) -> list[str]:
    return [line.split(" (")[0].strip() for line in lines if line.strip()]


def bubble(draft: Mapping, text: str, subject: str, attachments: Iterable[str], language: str) -> str:
    """The message exactly as it will go, ahead of the question card."""
    words = strings(language)
    recipient, channel = str(draft.get("recipient") or "").strip(), str(draft.get("channel") or "").strip()
    if recipient and channel:
        header = f"{words['to']} {recipient} {words['via']} {channel}"
    else:
        header = f"{words['to']} {recipient or channel}" if recipient or channel else words["message"]
    parts = [header]
    if subject.strip():
        parts.append(f"{words['subject']}: {subject.strip()}")
    parts.append("")
    parts.append(text.strip())
    if names := [name for name in attachments if name]:
        parts += ["", f"{words['attachments']}: {', '.join(names)}"]
    return "\n".join(parts)
