from __future__ import annotations

from dataclasses import dataclass
from enum import Enum

DEFAULT_MEMBER_TURNS_PER_HOUR = 30


class Audience(str, Enum):
    OWNER = "owner"
    MEMBER = "member"


class AdmissionKind(Enum):
    OWNER = "owner"
    MEMBER = "member"
    REPLY = "reply"
    REFUSED = "refused"


class AudiencePolicyKind(str, Enum):
    OWNER_ONLY = "owner_only"
    WORKSPACE = "workspace"
    LISTED = "listed"


@dataclass(frozen=True)
class SenderFacts:
    user_id: str
    scope_id: str
    same_scope: bool
    is_bot: bool
    is_restricted: bool
    display_name: str


@dataclass(frozen=True)
class AudiencePolicy:
    kind: AudiencePolicyKind
    members: frozenset[str]
    include_restricted: bool
    member_turns_per_hour: int

    @classmethod
    def owner_only(cls) -> AudiencePolicy:
        return cls(AudiencePolicyKind.OWNER_ONLY, frozenset(), False, DEFAULT_MEMBER_TURNS_PER_HOUR)

    @classmethod
    def from_config(cls, raw: object) -> AudiencePolicy:
        if not isinstance(raw, dict):
            return cls.owner_only()
        try:
            kind = AudiencePolicyKind(raw.get("policy"))
        except ValueError:
            return cls.owner_only()
        members = raw.get("members", [])
        include_restricted = raw.get("include_restricted", False)
        per_hour = raw.get("member_turns_per_hour", DEFAULT_MEMBER_TURNS_PER_HOUR)
        valid = (
            isinstance(members, list) and all(isinstance(m, str) and m for m in members)
            and isinstance(include_restricted, bool)
            and isinstance(per_hour, int) and not isinstance(per_hour, bool) and per_hour > 0
        )
        return cls(kind, frozenset(members), include_restricted, per_hour) if valid else cls.owner_only()

    def admits_user(self, user_id: str | None) -> bool:
        if self.kind is AudiencePolicyKind.WORKSPACE:
            return True
        return self.kind is AudiencePolicyKind.LISTED and user_id in self.members

    def admits(self, facts: SenderFacts | None) -> bool:
        if facts is None or facts.is_bot or not facts.same_scope:
            return False
        return (self.include_restricted or not facts.is_restricted) and self.admits_user(facts.user_id)


@dataclass(frozen=True)
class Admission:
    kind: AdmissionKind
    facts: SenderFacts | None = None
    ask_id: str | None = None
    needs_facts: bool = False

    @property
    def audience(self) -> Audience:
        return Audience.MEMBER if self.kind is AdmissionKind.MEMBER else Audience.OWNER
