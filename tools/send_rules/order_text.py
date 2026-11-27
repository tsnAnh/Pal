from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass
from typing import Optional

from tools.routine_send import reads_as_address

_MAX_CHARS = 200
_MAX_LINES = 3
_MAX_OBJECT_WORDS = 8
_QUOTING = frozenset('?"“”«»`')
_ENDINGS = ".,!:;…"
_PLATFORM_PREFIX = re.compile(r"^[a-z_]+:(?=\S)")


def _phrases(*texts: str) -> tuple[tuple[str, ...], ...]:
    return tuple(sorted((tuple(unicodedata.normalize("NFC", text).split()) for text in texts), key=len, reverse=True))


_ONCE = _phrases(
    "send it", "send this", "send that", "send them", "send now", "send there", "just send", "you can send",
    "you may send", "go ahead and send", "post it", "post this", "post that", "post them", "post now", "just post",
    "you can post", "you may post", "go ahead and post",
    "gửi đi", "gửi luôn", "gửi nó", "gửi cái này", "gửi cái đó", "cứ gửi", "gửi nhé", "đăng đi", "đăng luôn",
    "cứ đăng", "đăng nhé", "được phép gửi")
_STANDING = _phrases(
    "stop asking", "stop asking me", "stop asking before sending", "don't ask again", "don't ask me again",
    "do not ask again", "do not ask me again", "never ask again", "no need to ask again", "send freely",
    "post freely", "always send", "always post", "always send it", "always post it",
    "đừng hỏi nữa", "đừng hỏi lại", "đừng hỏi lại nữa", "không cần hỏi nữa", "không cần hỏi lại", "khỏi hỏi nữa",
    "khỏi hỏi lại", "khỏi cần hỏi nữa", "gửi thoải mái", "cứ gửi thoải mái", "đăng thoải mái", "luôn gửi")
_MODIFIERS = _phrases("from now on", "going forward", "từ giờ", "từ nay", "từ giờ trở đi", "từ nay trở đi")
_FILLER = _phrases(
    "yes", "yeah", "ok", "okay", "oke", "please", "pls", "just", "now", "then", "and", "also", "so", "thanks",
    "go ahead", "you can", "you may", "bot", "hey", "there", "it", "no need to ask", "you don't need to ask",
    "don't ask", "don't ask me", "ừ", "ừm", "vâng", "dạ", "nhé", "nha", "nhá", "đi", "luôn", "thì", "và", "cũng",
    "giúp", "hộ", "bạn", "cứ", "vào đó", "lên đó", "ở đó", "đó", "đừng hỏi", "không cần hỏi", "khỏi hỏi",
    "khỏi cần hỏi")
_VERBS = frozenset(unicodedata.normalize("NFC", "send post gửi đăng").split())
_PREPOSITIONS = frozenset(unicodedata.normalize("NFC", "to into vào lên tới đến sang").split())
_CHANNEL_WORDS = frozenset({"channel", unicodedata.normalize("NFC", "kênh"), "the"})
_LOOSE_PREPOSITIONS = _PREPOSITIONS | frozenset(unicodedata.normalize("NFC", "in on qua cho").split())
_ALWAYS = frozenset(unicodedata.normalize("NFC", "always luôn").split())
_OBJECT_WORDS = frozenset(unicodedata.normalize(
    "NFC",
    "the a an this that these those it them our today's yesterday's weekly daily monthly quarterly latest new final "
    "full same short revenue sales report reports summary numbers number figures stats metrics update updates "
    "message messages reminder digest text version result results data "
    "báo cáo doanh thu số liệu tin nhắn nội dung bản cái này đó đấy hôm nay tuần tháng ngày mới nhất tóm tắt cập "
    "nhật kết quả thông").split())


@dataclass(frozen=True)
class Order:
    standing: bool
    places: tuple[str, ...]


def _words(text: str) -> Optional[list[str]]:
    text = unicodedata.normalize("NFC", text).replace("’", "'").strip()
    if (not text or len(text) > _MAX_CHARS or text.count("\n") >= _MAX_LINES or _QUOTING & set(text)
            or any(line.lstrip().startswith(">") for line in text.splitlines())):
        return None
    return [word for raw in text.casefold().split() if (word := raw.rstrip(_ENDINGS).lstrip("("))
            and word not in {"-", "–", "—"}]


def _is_place(word: str) -> bool:
    return reads_as_address(_PLATFORM_PREFIX.sub("", word))


def _phrase_at(words: list[str], at: int, table: tuple[tuple[str, ...], ...]) -> Optional[tuple[str, ...]]:
    return next((phrase for phrase in table if tuple(words[at:at + len(phrase)]) == phrase), None)


def _place_at(words: list[str], at: int, prepositions: frozenset) -> tuple[int, Optional[str]]:
    index = at
    if index < len(words) and words[index] in prepositions:
        index += 1
    while index < len(words) and words[index] in _CHANNEL_WORDS:
        index += 1
    if index < len(words) and _is_place(words[index]):
        return index + 1, words[index]
    return at, None


def _named_send_at(words: list[str], at: int) -> tuple[int, Optional[str]]:
    """``send <object> to <place>``; only listed object words count, so any other word means it may say more."""
    if words[at] not in _VERBS:
        return at, None
    for index in range(at + 1, min(at + 2 + _MAX_OBJECT_WORDS, len(words))):
        if words[index] in _PREPOSITIONS:
            end, place = _place_at(words, index, _PREPOSITIONS)
            if place is not None:
                held = words[at + 1:index]
                return (end, place) if all(word in _OBJECT_WORDS for word in held) else (at, None)
    return at, None


def read_order(text: str) -> Optional[Order]:
    """The send order in an owner message, or ``None``. A whitelist: every word must belong to an order, so a
    question, a refusal, a condition or any second request reads as no order."""
    words = _words(text)
    if words is None:
        return None
    at, ordered, standing, places = 0, False, False, []
    while at < len(words):
        standing_phrase, once_phrase = _phrase_at(words, at, _STANDING), _phrase_at(words, at, _ONCE)
        always = words[at] in _ALWAYS
        if at + always < len(words) and (named := _named_send_at(words, at + always))[1] is not None:
            ordered, standing, at = True, standing or always, named[0]
            places.append(named[1])
        elif standing_phrase and len(standing_phrase) >= len(once_phrase or ()):
            standing = True
            ordered, at = True, at + len(standing_phrase)
        elif once_phrase:
            ordered, at = True, at + len(once_phrase)
        elif (placed := _place_at(words, at, _LOOSE_PREPOSITIONS))[1] is not None:
            at = placed[0]
            places.append(placed[1])
        elif modifier := _phrase_at(words, at, _MODIFIERS):
            standing, at = True, at + len(modifier)
        elif filler := _phrase_at(words, at, _FILLER):
            at += len(filler)
        else:
            return None
    return Order(standing, tuple(places)) if ordered else None
