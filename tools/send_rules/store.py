from __future__ import annotations

import json
import logging
import threading
import time
import uuid
from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import asdict, dataclass, replace
from pathlib import Path
from typing import Optional

from hermes_constants import get_hermes_home, profile_name_for_home
from tools.skill_usage import skill_file_lock
from utils import atomic_json_write

logger = logging.getLogger(__name__)

MAX_RULES = 200
_TEXT_FIELDS = ("id", "profile", "tool", "signature", "destination_label", "card")
_PUBLIC_FIELDS = ("id", "tool", "destination_label", "created_at", "last_used_at", "uses")
_thread_lock = threading.Lock()


@dataclass(frozen=True)
class SendRuleCandidate:
    tool: str
    signature: str
    destination_label: str
    card: str


@dataclass(frozen=True)
class SendRule:
    id: str
    profile: str
    tool: str
    signature: str
    destination_label: str
    card: str
    created_at: float
    last_used_at: Optional[float]
    uses: int

    def public(self) -> dict:
        return {name: getattr(self, name) for name in _PUBLIC_FIELDS}


def rules_path() -> Path:
    return Path(get_hermes_home()) / "bot_mode" / "send_rules.json"


def current_profile() -> str:
    return profile_name_for_home(get_hermes_home()) or "default"


def _parse(row: object) -> SendRule:
    try:
        rule = SendRule(**row)
    except TypeError as exc:
        raise ValueError("a send rule has the wrong fields") from exc
    if not (all(isinstance(getattr(rule, name), str) for name in _TEXT_FIELDS)
            and isinstance(rule.created_at, (int, float)) and isinstance(rule.uses, int)
            and isinstance(rule.last_used_at, (int, float, type(None)))):
        raise ValueError("a send rule has the wrong field types")
    return rule


def _read(path: Path) -> list[SendRule]:
    """This profile's rules. A file copied from another bot holds nothing for this one."""
    try:
        text = path.read_text(encoding="utf-8-sig")
    except FileNotFoundError:
        return []
    data = json.loads(text)
    rows = data.get("rules") if isinstance(data, dict) else None
    if not isinstance(rows, list):
        raise ValueError("the send rule file holds no rule list")
    profile = current_profile()
    return [rule for rule in map(_parse, rows) if rule.profile == profile]


def _write(path: Path, rules: list[SendRule]) -> None:
    atomic_json_write(path, {"rules": [asdict(rule) for rule in rules]}, mode=0o600, fsync_dir=True)


@contextmanager
def _locked() -> Iterator[Path]:
    path = rules_path()
    with _thread_lock, skill_file_lock(path.with_name(f"{path.name}.lock")):
        yield path


def list_rules() -> list[SendRule]:
    return _read(rules_path())


def _matches(rule: SendRule, tool: str, signature: str) -> bool:
    return rule.tool == tool and rule.signature == signature


def find(tool: str, signature: str) -> Optional[SendRule]:
    return next((rule for rule in list_rules() if _matches(rule, tool, signature)), None)


def remember(candidate: SendRuleCandidate) -> SendRule:
    with _locked() as path:
        rules = _read(path)
        known = next((rule for rule in rules if _matches(rule, candidate.tool, candidate.signature)), None)
        if known is not None:
            return known
        added = SendRule(id=f"sr_{uuid.uuid4().hex}", profile=current_profile(), created_at=time.time(),
                         last_used_at=None, uses=0, **asdict(candidate))
        kept = sorted(rules, key=lambda rule: rule.last_used_at or rule.created_at, reverse=True)[:MAX_RULES - 1]
        _write(path, [*(rule for rule in rules if rule in kept), added])
    logger.info("send rule saved bot=%s tool=%s destination=%s", added.profile, added.tool, added.destination_label)
    return added


def use(tool: str, signature: str) -> Optional[SendRule]:
    with _locked() as path:
        rules = _read(path)
        for index, rule in enumerate(rules):
            if _matches(rule, tool, signature):
                rules[index] = replace(rule, uses=rule.uses + 1, last_used_at=time.time())
                _write(path, rules)
                return rules[index]
    return None


def revoke(rule_id: str) -> bool:
    with _locked() as path:
        rules = _read(path)
        kept = [rule for rule in rules if rule.id != rule_id]
        if len(kept) == len(rules):
            return False
        _write(path, kept)
    logger.info("send rule revoked bot=%s id=%s", current_profile(), rule_id)
    return True
