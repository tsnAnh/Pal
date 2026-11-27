from __future__ import annotations

import re
import unicodedata
from collections.abc import Mapping, Sequence
from pathlib import PurePosixPath

from agent.redact import redact_sensitive_text

TITLE_LIMIT = 60
FALLBACK_TITLE = "Scheduled task"

_SLUG = re.compile(r"[a-z0-9_.:-]+")
_UUID = re.compile(r"[0-9a-f]{8}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{12}", re.IGNORECASE)
_HEX_ID = re.compile(r"(?=[0-9a-f]*\d)[0-9a-f]{8,}", re.IGNORECASE)
_HEX_TOKEN = re.compile(r"(?=[0-9a-f]*\d)(?=[0-9a-f]*[a-f])[0-9a-f]{8,}", re.IGNORECASE)
_SEPARATORS = re.compile(r"[_.:\-\s]+")
_LEADING_MARKS = re.compile(r"^[\W_]+")
_CLAUSE_END = re.compile(r"[;。！？；]|[.!?](?=\s|$)")


def is_raw_name(name: str) -> bool:
    return any(pattern.fullmatch(name) for pattern in (_SLUG, _UUID, _HEX_ID))


def _sentence(text: str) -> str:
    text = " ".join(text.split())
    while text and unicodedata.category(text[-1]).startswith("P"):
        text = text[:-1].rstrip()
    if not any(char.isalpha() for char in text):
        return ""
    return text[:1].upper() + text[1:]


def _clip(text: str) -> str:
    if len(text) <= TITLE_LIMIT:
        return text
    head = text[:TITLE_LIMIT + 1]
    phrase = re.split(r"[,，、]", head)
    if len(phrase) > 1 and len(", ".join(phrase[:-1]).split()) >= 3:
        return head[:len(head) - len(phrase[-1]) - 1]
    return head.rsplit(" ", 1)[0] if " " in head else text[:TITLE_LIMIT]


def _from_prompt(prompt: str) -> str:
    prompt = unicodedata.normalize("NFC", redact_sensitive_text(prompt, force=True))
    for line in prompt.splitlines():
        clause = _CLAUSE_END.split(_LEADING_MARKS.sub("", line), maxsplit=1)[0]
        if title := _sentence(_clip(" ".join(clause.split()))):
            return title
    return ""


def _from_slug(slug: str) -> str:
    words = _SEPARATORS.split(_UUID.sub(" ", slug))
    return _sentence(_clip(" ".join(word for word in words if word and not _HEX_TOKEN.fullmatch(word))))


def readable_job_name(name: str, prompt: str = "", labels: Sequence[str] = (), *, creating: bool = False) -> str:
    if name and not is_raw_name(name.strip()):
        return name
    name = name.strip()
    slug = "" if _HEX_ID.fullmatch(name) else _from_slug(name)
    derived = _from_prompt(prompt)
    candidates = (derived, slug) if creating else (slug, derived)
    return next(filter(None, (*candidates, *map(_from_slug, labels))), FALLBACK_TITLE)


def job_labels(skills: Sequence[str], script: str | None) -> list[str]:
    return [*skills, *([PurePosixPath(script).stem] if script else [])]


def job_title(job: Mapping[str, object]) -> str:
    skills = job.get("skills") or ([job["skill"]] if job.get("skill") else [])
    return readable_job_name(
        str(job.get("name") or ""), str(job.get("prompt") or ""),
        job_labels([str(skill) for skill in skills], str(job.get("script") or "") or None))
