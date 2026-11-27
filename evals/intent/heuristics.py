from __future__ import annotations

import json
import re
import unicodedata
from collections.abc import Mapping
from dataclasses import dataclass
from enum import Enum

from agent.tool_result_classification import FILE_MUTATING_TOOL_NAMES, NO_EFFECT_TOOL_NAMES, has_failure_marker
from gateway.proactive_scorecard.patterns import fold, is_bare_yes_no, option_labels, question_text
from tools.bot_mode_drafts import classify_outbound

STEM_CAP = 60
CORRECTION_SCAN_CHARS = 300
_TAIL_LINES = 8
_PHRASE_LINES = 3


class Signal(Enum):
    TRAILING_QUESTION = "trailing_question"
    ASK_PHRASE = "ask_phrase"
    OPTION_LIST = "option_list"


class Change(Enum):
    CODE_EDIT = "code_edit"
    OUTBOUND_SEND = "outbound_send"
    SPEND = "spend"
    CONFIG = "config"
    UNCLASSIFIED = "unclassified"


def _compile(*patterns: str) -> tuple[re.Pattern, ...]:
    return tuple(re.compile(pattern) for pattern in patterns)


def _any(patterns: tuple[re.Pattern, ...], folded: str) -> bool:
    return any(pattern.search(folded) for pattern in patterns)


_ASK_PHRASES = _compile(
    r"\bwhich (one|option|would you|do you)\b",
    r"\b(do|would) you (want|like|prefer)\b",
    r"(?<!neu )\b(ban|anh|chi|sep) (co )?muon\b",
    r"\bchon (cai|phuong an|option) nao\b",
)
_CHOICE_CUES = _compile(r"\?", r"\b(option|choose|pick|select|reply with|chon|phuong an|lua chon)\b")
_NUMBERED_OPTION = re.compile(r"^\s*(?:\d{1,2}|[A-Da-d])[.)]\s+\S")
_RESTATEMENTS = _compile(
    r"\bso you (want|need|mean)\b",
    r"(?<!do )(?<!would )\byou (want|need) me to\b",
    r"\bto confirm\b",
    r"\bif i understand\b",
    r"\b(my understanding|as i understand|i understand (that )?you)\b",
    r"\b(minh|toi|em) hieu (la|rang|y)\b",
    r"\btheo (minh|toi|em) hieu\b",
    r"\by (ban|anh|chi) la\b",
    r"\btuc la (ban|anh|chi)\b",
    r"\bde xac nhan\b",
)

CORRECTION_SHAPES: Mapping[str, tuple[re.Pattern, ...]] = {
    "not_what_i_meant": _compile(r"\bi meant\b", r"\bnot what i (mean|meant|ask|asked|said|want|wanted)\b", r"\bthat'?s not it\b"),
    "i_said": _compile(r"\bi (already |just )?(said|told you)\b",
                       r"\b(toi|minh|anh|em|chi|tao) (da )?(noi|bao|dan) (la|roi)\b"),
    "khong_phai": _compile(r"^\W*(khong,? )?khong phai\b",
                           r"\bkhong phai (vay|the|cai (do|nay|kia)|nhu (vay|the)|y (toi|minh|anh|em|chi))\b"),
    "y_toi_la": _compile(r"\by (toi|minh|anh|em|chi|tao) (la|muon noi)\b"),
    "wrong": _compile(r"\bsai (roi|bet)\b", r"\b(hieu|lam) sai\b", r"\bmisunderst(ood|and)\b",
                      r"\b(that'?s|this is|you'?re|you got (it|that)) wrong\b", r"\bwrong again\b"),
}
_AGAIN = re.compile(r"\bagain\b")

_BY_NAME: Mapping[str, Change] = {
    **dict.fromkeys(FILE_MUTATING_TOOL_NAMES, Change.CODE_EDIT),
    **dict.fromkeys(("slack_post_message", "slack_send_dm", "feishu_drive_reply_comment",
                     "feishu_drive_add_comment"), Change.OUTBOUND_SEND),
    **dict.fromkeys(("image_generate", "video_generate", "xai_video_edit", "xai_video_extend"), Change.SPEND),
    "skill_manage": Change.CONFIG,
}
_CONFIG_READ_ACTIONS: Mapping[str, frozenset[str]] = {
    "cronjob_manage": frozenset({"list"}),
    "manage_connections": frozenset({"", "status", "display"}),
    "desktop_project": frozenset({"list"}),
}
_NOT_WORK = NO_EFFECT_TOOL_NAMES | frozenset({
    "clarify", "todo_list", "memory", "commitment", "tool_search", "tool_describe", "kanban_show", "kanban_list",
    "kanban_heartbeat", "react_to_message", "slack_react", "slack_list_channels", "slack_list_users",
    "slack_read_channel", "slack_read_thread", "feishu_doc_read", "feishu_drive_list_comments",
    "feishu_drive_list_comment_replies", "x_search", "video_analyze", "read_window_below",
})
_SPEND_WORDS = frozenset({"pay", "purchase", "buy", "charge", "checkout", "subscribe"})
_READ_WORDS = frozenset({"list", "get", "read", "search", "fetch", "find", "count"})


def change_of(name: str, arguments: dict) -> Change | None:
    if name in _BY_NAME:
        return _BY_NAME[name]
    if name in _CONFIG_READ_ACTIONS:
        return None if str(arguments.get("action") or "") in _CONFIG_READ_ACTIONS[name] else Change.CONFIG
    if name in _NOT_WORK:
        return None
    words = set(name.lower().split("__")[-1].split("_"))
    if name.startswith(("mcp__", "connectors__")) and words & _SPEND_WORDS and not words & _READ_WORDS:
        return Change.SPEND
    if classify_outbound(name, arguments) is not None:
        return Change.OUTBOUND_SEND
    return None if name == "send_message" else Change.UNCLASSIFIED


def failed(result: str) -> bool:
    try:
        payload = json.loads(result)
    except ValueError:
        payload = None
    return has_failure_marker(result) or (isinstance(payload, dict) and payload.get("success") is False)


_FENCED_BLOCK = re.compile(r"```.*?(?:```|\Z)", re.DOTALL)
_QUOTED_LINE = re.compile(r"^\s*>.*$", re.MULTILINE)


def own_words(text: str) -> str:
    return _QUOTED_LINE.sub("", _FENCED_BLOCK.sub("", text)).strip()


def question_signals(text: str) -> frozenset[Signal]:
    lines = [line for line in text.splitlines() if line.strip()]
    if not lines:
        return frozenset()
    tail = lines[-_TAIL_LINES:]
    folded_tail = fold("\n".join(tail))
    found = set()
    if question_text(lines[-1]) is not None:
        found.add(Signal.TRAILING_QUESTION)
    if _any(_ASK_PHRASES, fold("\n".join(lines[-_PHRASE_LINES:]))):
        found.add(Signal.ASK_PHRASE)
    if sum(1 for line in tail if _NUMBERED_OPTION.match(line)) >= 2 and (
            _any(_CHOICE_CUES, folded_tail) or _any(_ASK_PHRASES, folded_tail)):
        found.add(Signal.OPTION_LIST)
    return frozenset(found)


def restates(text: str) -> bool:
    return _any(_RESTATEMENTS, fold(text))


def correction_shapes(text: str) -> frozenset[str]:
    folded = fold(text[:CORRECTION_SCAN_CHARS])
    return frozenset(name for name, patterns in CORRECTION_SHAPES.items() if _any(patterns, folded))


def says_again(text: str) -> bool:
    return bool(_AGAIN.search(fold(text[:CORRECTION_SCAN_CHARS])))


def question_stem(text: str) -> str:
    sentences = [part.strip(" *_#>-") for part in re.split(r"(?<=[.?!…])\s+|\n+", text.strip())]
    sentences = [part for part in sentences if part]
    for matches in (lambda part: "?" in part, lambda part: _any(_ASK_PHRASES, fold(part))):
        for sentence in reversed(sentences):
            if matches(sentence):
                return sentence
    rows = text.strip().splitlines()
    first_option = next((index for index, row in enumerate(rows) if _NUMBERED_OPTION.match(row)), len(rows))
    lead = [row.strip() for row in rows[:first_option] if row.strip()]
    return lead[-1] if lead else (sentences[-1] if sentences else "")


def listed_options(text: str, signals: frozenset[Signal]) -> tuple[str, ...]:
    return option_labels(text) if Signal.OPTION_LIST in signals else ()


@dataclass(frozen=True, slots=True)
class AskKey:
    words: frozenset[str]
    numbers: frozenset[str]
    options: frozenset[str]

    @classmethod
    def of(cls, stem: str, options: tuple[str, ...]) -> AskKey:
        words = frozenset(re.findall(r"\w+", fold(stem)))
        named = () if is_bare_yes_no(options) else options
        return cls(words, frozenset(word for word in words if any(ch.isdigit() for ch in word)),
                   frozenset(" ".join(re.findall(r"\w+", fold(option))) for option in named))

    def repeats(self, other: AskKey) -> bool:
        if self.numbers != other.numbers:
            return False
        stem_match = _overlap(self.words, other.words)
        if self.options and other.options:
            return _overlap(self.options, other.options) >= 0.6 and stem_match >= 0.4
        return min(len(self.words), len(other.words)) >= 3 and stem_match >= 0.8


def _overlap(left: frozenset[str], right: frozenset[str]) -> float:
    union = left | right
    return len(left & right) / len(union) if union else 0.0


_SHAPE_WORDS = frozenset("""
a an and any anything after again all also are at be before by can cancel change check choose confirm continue could
create delete deploy did do does don't done else first fix for from go ahead if in is it its i i'm keep later let like
make may me merge might more must my need new next no not now of ok okay on one ones open option options or our out pick
post prefer proceed publish ready remove reply right run save schedule select send sent set shall should so some start
still stop that the them there these this those to today tomorrow us use wait want was we what when where which who why
will with would write yes yet you your add update approve correct here how
anh bạn chạy chị chọn chờ cho chưa cái có cần của dùng đã đang đâu đây để đi đó được đúng đăng em gì giữ gửi hay hoặc
huỷ hủy khi không kia ko làm lại luôn lựa mình muốn nào nên nha nhé ngay này phương án sao sau sẽ sếp sửa thêm thế tiếp
tôi tạo trước và vậy với xem xong xóa xoá à ạ hả ai là
""".split())
_SKELETON_TOKEN = re.compile(r"\w+(?:['’]\w+)*|\?")


def redacted_shape(stem: str) -> str:
    shown: list[str] = []
    for index, token in enumerate(_SKELETON_TOKEN.findall(unicodedata.normalize("NFC", stem))):
        plain_case = token.islower() or token == "I" or index == 0
        if token == "?" or (plain_case and token.casefold().replace("’", "'") in _SHAPE_WORDS):
            shown.append(token)
        elif shown[-1:] != ["_"]:
            shown.append("_")
    return " ".join(shown).replace(" ?", "?")[:STEM_CAP]
