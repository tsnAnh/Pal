"""Two bubbles for every ask: the details as a normal message first, then one short question card.

A bot that puts a summary, a cover letter or a field list inside the question buries the choice.
``split_question`` is the one place that enforces the shape, so every bot, client and connector
gets it; the agent runs it before the tool-call turn is persisted (``agent/turn_tool_round.py``).
"""
from __future__ import annotations

import json
import re
from typing import Any

# One line a phone card shows without wrapping past a thumb's reach; longer text is content.
QUESTION_MAX_CHARS = 160
# A button label: "Approve", "Edit", "Send as drafted". Anything longer is content, not a label.
OPTION_MAX_CHARS = 80
NEUTRAL_QUESTION = "Go ahead with this?"

_FENCE = "```"
_LIST_LINE = re.compile(r"^\s*(?:[-*•]|\d+[.)])\s+\S", re.MULTILINE)
_PARAGRAPH_BREAK = re.compile(r"\n\s*\n")
_SENTENCE_END = re.compile(r"(?<=[.!?…])\s+")


def _is_content(text: str) -> bool:
    return (len(text) > QUESTION_MAX_CHARS or bool(_PARAGRAPH_BREAK.search(text)) or _FENCE in text
            or bool(_LIST_LINE.search(text)))


def _fits_as_question(text: str) -> bool:
    return (text.endswith("?") and len(text) <= QUESTION_MAX_CHARS and "\n" not in text
            and _FENCE not in text and not _LIST_LINE.match(text))


def _pieces(text: str) -> list[tuple[int, int]]:
    pieces: list[tuple[int, int]] = []
    for para in re.finditer(r"[^\n]+(?:\n(?!\s*\n)[^\n]+)*", text):
        start = para.start()
        for part in _SENTENCE_END.split(para.group()):
            if part:
                found = text.index(part, start)
                pieces.append((found, found + len(part)))
                start = found + len(part)
    return pieces


def split_question(text: str) -> tuple[str, str]:
    """``(details, question)``. A short single-line question comes back untouched with empty details.
    Otherwise the last paragraph or sentence that ends with ``?`` and fits ``QUESTION_MAX_CHARS`` is the
    question and every other character is the details; with no such sentence the question is
    ``NEUTRAL_QUESTION`` and all the text is the details."""
    text = text.strip()
    if not _is_content(text):
        return "", text
    for start, end in reversed(_pieces(text)):
        candidate = text[start:end].strip()
        if _fits_as_question(candidate):
            details = f"{text[:start].rstrip()}\n\n{text[end:].lstrip()}".strip()
            return details, candidate
    return text, NEUTRAL_QUESTION


def split_clarify_arguments(arguments: Any) -> tuple[Any, str]:
    """``(arguments, details)`` for a clarify tool call's raw arguments (JSON text or dict): each
    long question is replaced by its short line and the details of every question, in order, are
    joined into one message. Arguments that do not parse or carry no long question come back as given."""
    parsed = _parsed(arguments)
    questions = parsed.get("questions") if isinstance(parsed, dict) else None
    if not isinstance(questions, list):
        return arguments, ""
    details: list[str] = []
    rewritten: list[Any] = []
    for item in questions:
        text = item.get("question") if isinstance(item, dict) else None
        if not isinstance(text, str) or not text.strip():
            rewritten.append(item)
            continue
        detail, short = split_question(text)
        if detail:
            details.append(detail)
        if preview := _send_preview_text(item):
            details.append(preview)
        rewritten.append({**item, "question": short} if detail else item)
    if not details:
        return arguments, ""
    out = {**parsed, "questions": rewritten}
    return (out if isinstance(arguments, dict) else json.dumps(out, ensure_ascii=False)), "\n\n".join(details)


def _send_preview_text(item: Any) -> str:
    """What a ``send`` question will authorize, rendered by code from the call itself so the owner reads the
    exact message, recipient and thread the pick approves."""
    from tools.bot_mode_drafts import preview_text, send_preview
    outbound = send_preview(item.get("send")) if isinstance(item, dict) else None
    return preview_text(outbound) if outbound is not None else ""


def _parsed(arguments: Any) -> Any:
    if isinstance(arguments, dict):
        return arguments
    if not isinstance(arguments, str):
        return None
    try:
        return json.loads(arguments)
    except ValueError:
        return None


def with_details_first(content: Any, details: str) -> str:
    """The assistant message content once ``details`` ride along: what the bot already wrote, then the details."""
    written = content.strip() if isinstance(content, str) else ""
    return f"{written}\n\n{details}" if written else details
