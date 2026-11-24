from __future__ import annotations

import logging
from dataclasses import dataclass
from typing import Any, Optional

from tools.clarify_tool import display_choices, strip_recommended

logger = logging.getLogger(__name__)

INSTALL_CHOICE = "Install and set up"
NOT_NOW_CHOICE = "Not now"

DECLINED_DETAIL = "The owner chose Not now. It is not installed; do not offer or retry it in this turn."
UNANSWERED_DETAIL = "The owner did not answer the install question. It is not installed; do not retry it in this turn."
UNATTENDED_DETAIL = (
    "Not installed: this run has no one to ask, and a connector is installed only after the owner agrees "
    "in the question form. Tell the owner it needs installing; do not retry it in this run."
)


@dataclass(frozen=True)
class Verdict:
    install: bool
    detail: str = ""
    unattended: bool = False


def _entry(name: str) -> Any:
    from hermes_cli.mcp_catalog import get_entry

    return get_entry(name)


def title_of(name: str) -> str:
    return " ".join(part.capitalize() for part in name.replace("_", "-").split("-") if part) or name


def _needs(entry: Any) -> str:
    auth = entry.auth
    if auth.type == "oauth":
        return "You sign in to your account in a browser."
    keys = [spec.prompt or spec.name for spec in auth.env or [] if spec.required]
    if auth.type == "api_key" and keys:
        return f"It needs {', '.join(keys)}, which you enter in the app, never in chat."
    return "It needs no account or key."


def details_text(name: str) -> str:
    from tools.connectors.mcp_launch import launch_for

    entry = _entry(name)
    if entry is None:
        return f"{title_of(name)} is not installed on this device yet."
    lines = [f"{title_of(name)}: {' '.join(str(entry.description).split())}"]
    launch = launch_for("install", name)
    if launch:
        verb = "contact" if launch.get("kind") == "remote" else "run"
        lines.append(f"Installing it will {verb} {launch['target']}.")
    lines.append(_needs(entry))
    return "\n".join(lines)


def _question(name: str) -> str:
    return f"Install {title_of(name)} for this bot?"


def _asker() -> Optional[Any]:
    from tools.approval_context import _no_user_can_answer
    from tools.mcp_elicitation_form import current_form_asker

    return None if _no_user_can_answer() else current_form_asker()


def ask_install(names: list[str]) -> dict[str, Verdict]:
    asker = _asker()
    if asker is None:
        return {name: Verdict(False, UNATTENDED_DETAIL, unattended=True) for name in names}
    from tools.details_bubble import post_details

    post_details("\n\n".join(details_text(name) for name in names))
    offered = [INSTALL_CHOICE, NOT_NOW_CHOICE]
    questions = [{"qid": f"q{index}", "question": _question(name), "choices": display_choices(offered, True),
                  "choices_offered": list(offered), "multi_select": False, "default": None}
                 for index, name in enumerate(names)]
    try:
        reply = asker(questions) or {}
    except Exception:
        logger.warning("connector install question failed", exc_info=True)
        reply = {}
    if reply.get("outcome") != "submitted":
        return {name: Verdict(False, UNANSWERED_DETAIL) for name in names}
    answers = reply.get("answers") or {}
    return {name: _verdict(answers.get(f"q{index}")) for index, name in enumerate(names)}


def _verdict(answer: Any) -> Verdict:
    if isinstance(answer, str) and strip_recommended(answer).casefold() == INSTALL_CHOICE.casefold():
        return Verdict(True)
    return Verdict(False, DECLINED_DETAIL)
