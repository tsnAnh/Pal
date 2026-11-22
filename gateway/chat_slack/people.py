from __future__ import annotations

from typing import Any

from tui_gateway.chat_install import PeoplePage
from tui_gateway.contracts.chat_provider import Person

from .api import SlackApi, SlackSetupError

PAGE_SIZE = 200
PAGE_TARGET = 50
MAX_PAGES = 5
SLACKBOT_ID = "USLACKBOT"


def person_of(member: Any, team_id: str) -> Person | None:
    if not isinstance(member, dict) or not member.get("id") or member.get("id") == SLACKBOT_ID:
        return None
    if member.get("deleted") or member.get("is_bot") or member.get("is_app_user") or member.get("is_stranger"):
        return None
    if member.get("team_id") and team_id and member["team_id"] != team_id:
        return None
    profile = member.get("profile") if isinstance(member.get("profile"), dict) else {}
    display = str(profile.get("display_name") or "").strip()
    name = str(member.get("real_name") or profile.get("real_name") or display or member.get("name") or "").strip()
    return Person(id=str(member["id"]), name=name, display_name=display,
                  is_restricted=bool(member.get("is_restricted") or member.get("is_ultra_restricted")))


def _matches(person: Person, needle: str) -> bool:
    return not needle or needle in f"{person.name} {person.display_name} {person.id}".lower()


def list_people(api: SlackApi, token: str, team_id: str, query: str, cursor: str) -> PeoplePage:
    needle = query.strip().lower()
    found: list[Person] = []
    for _ in range(MAX_PAGES):
        body = api.call("users.list", token=token, data={"limit": str(PAGE_SIZE), "cursor": cursor})
        found += [p for m in body.get("members", []) if (p := person_of(m, team_id)) and _matches(p, needle)]
        cursor = (body.get("response_metadata") or {}).get("next_cursor") or ""
        if not cursor or len(found) >= PAGE_TARGET:
            break
    return PeoplePage(found, cursor or None)


def names_for(api: SlackApi, token: str, team_id: str, member_ids: list[str]) -> dict[str, str]:
    names: dict[str, str] = {}
    for member_id in member_ids:
        try:
            person = person_of(api.call("users.info", token=token, data={"user": member_id}).get("user"), team_id)
        except SlackSetupError:
            continue
        if person is not None:
            names[member_id] = person.name
    return names
