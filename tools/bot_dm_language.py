from __future__ import annotations

import json
import logging
import re
import unicodedata
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path

logger = logging.getLogger(__name__)

WITHHELD_NOTICE = "Reply withheld: it was not in English. Ask again."
SEND_REJECTION = ("bot-to-bot messages must be English; rewrite this message in English "
                  "(quote the owner verbatim only after 'Owner said (verbatim):'). Rule: {reason}")
COUNTER_FILE = "bot-dm-language.json"
SEEN_KEYS_KEPT = 200

MIN_VIETNAMESE_WORDS = 2
MIN_FOREIGN_LETTERS = 3
MIN_WORDS_FOR_RATIO = 25
MIN_FUNCTION_WORD_RATIO = 0.04
MAX_SAMPLES = 3
VERBATIM_LEAD_CHARS = 80
VERBATIM_QUOTE_CHARS = 2000

FUNCTION_WORDS = frozenset(
    "the a an and or to of in on for is are was be it this that with as at by from not no yes pr run".split())
VIETNAMESE_LETTERS = frozenset("ăĂđĐơƠưƯ")
LATIN_LOOKALIKES = frozenset("µªº")
SCHEMELESS_TLDS = "com|org|net|io|dev|ai|app|co|edu|gov|vn|me|sh|xyz"

_FENCE = re.compile(r"```.*?```", re.DOTALL)
_INLINE_CODE = re.compile(r"`[^`\n]+`")
_VERBATIM_QUOTE = re.compile(
    rf"(?P<lead>(?:\(verbatim\)|verbatim:|owner['’]s words|owner said|the owner['’]s)[^\n\"“]{{0,{VERBATIM_LEAD_CHARS}}}?)"
    rf"(?P<quote>\"[^\"]{{1,{VERBATIM_QUOTE_CHARS}}}\"|“[^”]{{1,{VERBATIM_QUOTE_CHARS}}}”)", re.IGNORECASE)
_URL = re.compile(
    rf"https?://[^\s<>)\]]+|\b(?:www\.(?:[a-z0-9-]+\.)*[a-z]{{2,}}|(?:[a-z0-9-]+\.)+(?:{SCHEMELESS_TLDS}))\b(?:/[^\s<>)\]]*)?",
    re.IGNORECASE)
_TOKEN = re.compile(r"\S+")
_FILE_EXTENSION = re.compile(r"^.+\.[a-z][a-z0-9]{0,4}$")
_SHA = re.compile(r"\b[0-9a-f]{7,40}\b", re.IGNORECASE)
_HANDLE = re.compile(r"@[A-Za-z0-9_.-]+")
_CARD_ID = re.compile(r"\bt_[0-9a-f]+\b|\bPAL-\d+\b")
_WORD = re.compile(r"[^\W\d_]+")
_PLACEHOLDER = re.compile(r"\x00(\d+)\x00")
_BLANK_LINE = re.compile(r"\n\s*\n")


@dataclass(frozen=True)
class Verdict:
    ok: bool
    reason: str = ""
    samples: tuple[str, ...] = ()
    rule: str = ""


@dataclass(frozen=True)
class Screened:
    text: str
    dropped: int = 0
    rule: str = ""
    samples: tuple[str, ...] = ()


def _is_path(token: str) -> bool:
    core = token.strip("()[]{}<>\"'.,;:!?*")
    return "/" in core or "\\" in core or bool(_FILE_EXTENSION.match(core))


def _strip_exempt(text: str) -> str:
    text = _FENCE.sub(" ", text)
    text = _INLINE_CODE.sub(" ", text)
    text = _VERBATIM_QUOTE.sub(lambda m: m.group("lead") + " ", text)
    text = _URL.sub(" ", text)
    text = _TOKEN.sub(lambda m: " " if _is_path(m.group()) else m.group(), text)
    for pattern in (_SHA, _HANDLE, _CARD_ID):
        text = pattern.sub(" ", text)
    return text


@lru_cache(maxsize=4096)
def _is_foreign_letter(char: str) -> bool:
    if not char.isalpha() or char in LATIN_LOOKALIKES:
        return False
    return not unicodedata.name(char, "").startswith(("LATIN", "FULLWIDTH LATIN"))


def _first(words, limit: int = MAX_SAMPLES) -> tuple[str, ...]:
    return tuple(dict.fromkeys(words))[:limit]


def _quoted(samples: tuple[str, ...]) -> str:
    return ", ".join(f'"{sample}"' for sample in samples)


def _fail(rule: str, what: str, samples: tuple[str, ...]) -> Verdict:
    return Verdict(False, f"rule {rule}: {what} ({_quoted(samples)})", samples, rule)


def is_english(text: str) -> Verdict:
    residue = unicodedata.normalize("NFC", _strip_exempt(str(text or "")))
    words = _WORD.findall(residue)
    vietnamese = [w for w in words if any(c in VIETNAMESE_LETTERS or "Ạ" <= c <= "ỹ" for c in w)]
    if len(vietnamese) >= MIN_VIETNAMESE_WORDS:
        return _fail("a", f"{len(vietnamese)} words use Vietnamese letters", _first(vietnamese))
    foreign = [w for w in words if any(_is_foreign_letter(c) for c in w)]
    foreign_letters = sum(_is_foreign_letter(c) for c in residue)
    if foreign_letters >= MIN_FOREIGN_LETTERS:
        return _fail("b", f"{foreign_letters} letters are outside the Latin script", _first(foreign))
    if len(words) >= MIN_WORDS_FOR_RATIO:
        common = sum(w.lower() in FUNCTION_WORDS for w in words)
        if common / len(words) < MIN_FUNCTION_WORD_RATIO:
            return _fail("c", f"only {common} of {len(words)} words are common English words",
                         _first(w for w in words if w.lower() not in FUNCTION_WORDS))
    return Verdict(True)


def _split_paragraphs(text: str) -> list[str]:
    held: list[str] = []

    def hold(value: str) -> str:
        held.append(value)
        return f"\x00{len(held) - 1}\x00"

    masked = _FENCE.sub(lambda m: hold(m.group()), text.replace("\x00", ""))
    masked = _VERBATIM_QUOTE.sub(lambda m: m.group("lead") + hold(m.group("quote")), masked)

    def restore(paragraph: str) -> str:
        while _PLACEHOLDER.search(paragraph):
            paragraph = _PLACEHOLDER.sub(lambda m: held[int(m.group(1))], paragraph)
        return paragraph

    return [restore(p) for p in _BLANK_LINE.split(masked) if p.strip()]


def english_paragraphs(text: str) -> Screened:
    paragraphs = _split_paragraphs(str(text or ""))
    verdicts = [(p, is_english(p)) for p in paragraphs]
    failed = [v for _p, v in verdicts if not v.ok]
    if not failed:
        return Screened(str(text or ""))
    kept = "\n\n".join(p.strip() for p, v in verdicts if v.ok)
    return Screened(kept, len(failed), failed[0].rule, failed[0].samples)


def _record(kind: str, *, home: Path | str, sender: str, recipient: str, rule: str, dropped: int,
            samples: tuple[str, ...], key: str | None = None) -> None:
    from hermes_cli.active_sessions import _FileLock
    from utils import atomic_json_write

    path = Path(home) / COUNTER_FILE
    try:
        with _FileLock(path.with_suffix(".lock")):
            try:
                state = json.loads(path.read_text(encoding="utf-8-sig"))
            except FileNotFoundError:
                state = {}
            seen = [str(k) for k in state.get("seen", [])]
            if key is not None and key in seen:
                return
            rules = state.get("rules", {})
            rules[rule] = int(rules.get(rule, 0)) + 1
            state.update({kind: int(state.get(kind, 0)) + 1, "rules": rules,
                          "seen": (seen + ([key] if key is not None else []))[-SEEN_KEYS_KEPT:]})
            atomic_json_write(path, state, mode=0o600)
    except (OSError, ValueError, RuntimeError):
        logger.warning("bot-dm-language: counter not updated at %s", path, exc_info=True)
    logger.warning("bot-dm-language: %s from=%s to=%s rule=%s dropped=%d samples=%s",
                   kind, sender, recipient, rule, dropped, ",".join(s[:24] for s in samples))


def screen_send(body: str, *, home: Path | str, sender: str, target: str) -> str | None:
    verdict = is_english(body)
    if verdict.ok:
        return None
    _record("send", home=home, sender=sender, recipient=target, rule=verdict.rule,
            dropped=english_paragraphs(body).dropped, samples=verdict.samples)
    return SEND_REJECTION.format(reason=verdict.reason)


def screen_reply(text: str, *, original: str, home: Path | str, replier: str, sender: str, key: str) -> str:
    raw, kept = english_paragraphs(original), english_paragraphs(text)
    drifted = raw if raw.dropped else kept
    if not drifted.dropped:
        return text
    _record("reply", home=home, sender=replier, recipient=sender, rule=drifted.rule,
            dropped=max(raw.dropped, kept.dropped), samples=drifted.samples, key=key)
    return (kept.text if kept.dropped else text) or WITHHELD_NOTICE
