"""Audience lanes: who may talk to a bot and what each lane's session is built from.

- ``model``: the data shapes. ``Audience`` (a session's lane, encoded in its key), ``AdmissionKind`` and
  ``Admission`` (the verdict for one inbound event), ``SenderFacts`` (adapter-proven facts about a sender,
  absent unless positively proven) and ``AudiencePolicy`` (the owner's parsed setting; absent or malformed
  is owner-only).
- ``admission``: ``decide_admission``, the pure verdict over owner authorization, an open ask, the policy
  and the facts, and ``MemberRate``, the per-bot sliding window that bounds member turns.
- ``ingress``: the runner-side member gates, ``member_command_allowed`` (the member command table) and
  ``MemberRates`` (one ``MemberRate`` per served profile).
- ``posture``: the key marker, ``audience_of_key`` and ``posture_for_key``, the one fixed member posture
  (toolset, memory, context files, background review, system prompt) applied when an agent is built, plus
  the member command table and the texts members see.
"""

from gateway.audience.admission import MemberRate, RateVerdict, decide_admission
from gateway.audience.ingress import MemberRates, member_command_allowed
from gateway.audience.model import (
    DEFAULT_MEMBER_TURNS_PER_HOUR,
    Admission,
    AdmissionKind,
    Audience,
    AudiencePolicy,
    AudiencePolicyKind,
    SenderFacts,
)
from gateway.audience.posture import (
    MEMBER_COMMAND_REFUSAL,
    MEMBER_COMMANDS,
    MEMBER_MARKER,
    MEMBER_RATE_NOTICE,
    MEMBER_TOOLSETS,
    Posture,
    audience_of_key,
    posture_for_key,
)

__all__ = [
    "DEFAULT_MEMBER_TURNS_PER_HOUR",
    "MEMBER_COMMANDS",
    "MEMBER_COMMAND_REFUSAL",
    "MEMBER_MARKER",
    "MEMBER_RATE_NOTICE",
    "MEMBER_TOOLSETS",
    "Admission",
    "AdmissionKind",
    "Audience",
    "AudiencePolicy",
    "AudiencePolicyKind",
    "MemberRate",
    "MemberRates",
    "Posture",
    "RateVerdict",
    "SenderFacts",
    "audience_of_key",
    "decide_admission",
    "member_command_allowed",
    "posture_for_key",
]
