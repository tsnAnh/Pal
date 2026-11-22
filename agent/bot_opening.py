from __future__ import annotations

import json
import logging
from dataclasses import dataclass
from enum import Enum
from pathlib import Path
from typing import Any, Iterator, Sequence

logger = logging.getLogger(__name__)

QUESTION = "What do you want me for?"
CHOICES = ("Everyday personal assistant", "Help with my apps and work", "A specific new job")
_PITCH = "You haven't given me a job yet, so let's figure out where I'd help you most."


class OpeningDecision(Enum):
    PLAY = "play"
    CLEAR = "clear"
    NONE = "none"


@dataclass(frozen=True, slots=True)
class BotOpening:
    greeting: str
    question: str
    choices: tuple[str, ...]

    def clarify_args(self) -> dict[str, Any]:
        return {"questions": [{"question": self.question, "choices": list(self.choices), "recommend": False}]}


def build_opening(owner_name: str | None, bot_name: str) -> BotOpening:
    hello = f"Hi {owner_name}" if owner_name else "Hi"
    return BotOpening(f"{hello}, I'm {bot_name}. {_PITCH}", QUESTION, CHOICES)


def decide(*, pending: bool, first_hidden_turn: bool, has_role: bool) -> OpeningDecision:
    if not (pending and first_hidden_turn):
        return OpeningDecision.NONE
    return OpeningDecision.CLEAR if has_role else OpeningDecision.PLAY


def _can_ask(agent: Any) -> bool:
    return "clarify" in (getattr(agent, "valid_tool_names", None) or ()) and getattr(agent, "clarify_callback", None) is not None


def _was_answered(result: str | None) -> bool:
    try:
        responses = json.loads(result)["responses"]
    except (TypeError, ValueError, KeyError):
        return False
    return bool(responses) and isinstance(responses[0], dict) and responses[0].get("status") == "answered"


def _clear_pending(home: Path) -> None:
    from hermes_cli.bot_onboarding import clear_onboarding_pending
    try:
        clear_onboarding_pending(home)
    except OSError:
        logger.warning("could not clear onboarding_pending for profile %s", home.name, exc_info=True)


def _owner_name(home: Path) -> str | None:
    from tools.bot_mode_about_you import about_you_root, read_about_you
    return read_about_you(about_you_root(home))["name"] or None


def _bot_name(home: Path) -> str | None:
    from hermes_cli.profiles import read_profile_meta
    from hermes_constants import profile_name_for_home
    return read_profile_meta(home)["display_name"] or profile_name_for_home(home)


def _opening_steps(opening: BotOpening, home: Path) -> Iterator[tuple[str, str, dict]]:
    result = yield opening.greeting, "clarify", opening.clarify_args()
    if _was_answered(result):
        _clear_pending(home)


def bot_opening_prelude(agent: Any, history: Sequence[dict], *, hidden: bool) -> Iterator[tuple[str, str, dict]] | None:
    from agent.system_prompt import _agent_home
    from hermes_cli.bot_onboarding import read_onboarding_pending
    from tools.memory_tool_identity import ROLE_HEADING, IdentityError, has_section
    first_hidden_turn = hidden and not history and _can_ask(agent)
    home = _agent_home(agent) if first_hidden_turn else None
    pending = home is not None and read_onboarding_pending(home)
    try:
        has_role = pending and has_section(home, ROLE_HEADING)
    except IdentityError:
        return None
    decision = decide(pending=pending, first_hidden_turn=first_hidden_turn, has_role=has_role)
    if decision is OpeningDecision.CLEAR:
        _clear_pending(home)
    if decision is not OpeningDecision.PLAY:
        return None
    bot_name = _bot_name(home)
    if not bot_name:
        return None
    return _opening_steps(build_opening(_owner_name(home), bot_name), home)
