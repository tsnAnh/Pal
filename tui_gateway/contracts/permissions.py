"""Permissions (``methods_permissions.py``, ``tools/approval_rules.py``): the plain-language rules the smart
approval guardian applies, per profile. Every method rides ``profile`` and answers for that profile's bot.

Auto-Review is ``approvals.mode`` smart (on) against manual (off); it is never mapped to the mode that skips
approvals. Rules reach only the guardian's own prompt, never the agent's, and the deny globs and hardline
blocks still win over an Allow rule. Failures answer 5320 with ``error.data.code``: ``invalid_list``,
``empty_text``, ``text_too_long``, ``invalid_text``, ``invalid_id``, ``duplicate_rule`` (``data.list`` and
``data.rule`` name the existing rule), ``limit_reached``, ``invalid_enabled``, ``config_unreadable``, ``config_locked``.
"""

from __future__ import annotations

from .base import Result, WireEnum
from .common import ProfileParams
from .registry import method


class PermissionRuleList(WireEnum):
    ASK = "ask"
    ALLOW = "allow"


class PermissionsApprovalMode(WireEnum):
    MANUAL = "manual"
    SMART = "smart"
    OFF = "off"


class PermissionRule(Result):
    """A short sentence the user typed; ``created_at`` is ISO 8601 UTC."""

    id: str
    text: str
    created_at: str


class PermissionsState(Result):
    """``auto_review`` is true only under the smart guardian; ``approval_mode`` is the profile's real setting so a
    client can say approvals are off, in which case rules are stored and not applied."""

    auto_review: bool
    approval_mode: PermissionsApprovalMode
    ask: list[PermissionRule]
    allow: list[PermissionRule]


method("permissions.get", params=ProfileParams, result=PermissionsState,
       doc="Auto-Review state and both rule lists of one profile.")


class PermissionsSetAutoReviewParams(ProfileParams):
    enabled: bool


method("permissions.set_auto_review", params=PermissionsSetAutoReviewParams, result=PermissionsState,
       doc="Turn Auto-Review on (smart guardian) or off (manual prompts); idempotent, never writes the mode "
           "that skips approvals, and leaves an already-off profile as it is.")


class PermissionsRuleAddParams(ProfileParams):
    list: PermissionRuleList
    text: str


method("permissions.rules.add", params=PermissionsRuleAddParams, result=PermissionRule,
       doc="Add a rule (1 to 280 characters after trimming, at most 30 per list, never a repeat of a rule in "
           "either list); returns the stored rule.")


class PermissionsRuleRemoveParams(ProfileParams):
    id: str


class PermissionsRuleRemoveResult(Result):
    removed: bool


method("permissions.rules.remove", params=PermissionsRuleRemoveParams, result=PermissionsRuleRemoveResult,
       doc="Remove a rule from whichever list holds it; an unknown id answers removed false, so a retry converges.")
