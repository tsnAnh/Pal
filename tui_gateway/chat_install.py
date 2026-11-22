from __future__ import annotations

import abc
from dataclasses import dataclass
from typing import Any, Protocol

from tui_gateway.contracts.chat_provider import (
    Capabilities,
    CapabilityEntry,
    CapabilityMode,
    FixAction,
    IdentityPolicy,
    IdentityUpdateOutcome,
    IdentityProjection,
    Installation,
    NextAction,
    NextActionKind,
    Person,
    ProviderCapability,
    SetupError,
    SetupErrorCode,
    SetupEventKind,
    SetupState,
    SetupStep,
    SpaceJoinOutcome,
    SpaceLeaveOutcome,
    SpaceRef,
)


class ChatProviderError(Exception):
    def __init__(self, provider_id: str, operation: str):
        super().__init__(f"{provider_id}: {operation}")
        self.provider_id = provider_id
        self.operation = operation


class ProviderNotImplemented(ChatProviderError):
    pass


class StaleRevision(Exception):
    pass


@dataclass(frozen=True)
class BotIdentitySource:
    bot: str
    display_name: str
    avatar_path: str | None


@dataclass(frozen=True)
class AppCreated:
    app_id: str
    authorize_link: str


@dataclass(frozen=True)
class IdentityUpdate:
    outcome: IdentityUpdateOutcome
    identity: IdentityProjection
    next_action: NextAction


@dataclass(frozen=True)
class SpaceJoin:
    outcome: SpaceJoinOutcome
    next_action: NextAction


@dataclass(frozen=True)
class PeoplePage:
    people: list[Person]
    next_cursor: str | None


REDIRECT_PATH = "/webapp/chat-install/callback"
OWNER_DM_HOME_NAME = "Direct messages"
OWNER_FIELD_ID = "owner_member_id"


class ChatProvider(abc.ABC):
    provider_id: str
    allowed_users_env: str | None = None

    def _missing(self, operation: str) -> ProviderNotImplemented:
        return ProviderNotImplemented(self.provider_id, operation)

    def capabilities(self, workspace: str | None = None) -> Capabilities:
        raise self._missing("capabilities")

    def begin_install(self, state: SetupState, config_vault_item_id: str | None) -> AppCreated:
        raise self._missing("begin_install")

    def complete_install(self, state: SetupState, authorization_code: str) -> Installation:
        raise self._missing("complete_install")

    def identity_projection(self, source: BotIdentitySource) -> IdentityProjection:
        raise self._missing("identity_projection")

    def list_spaces(self, installation: Installation) -> list[SpaceRef]:
        raise self._missing("list_spaces")

    def join_space(self, installation: Installation, space_id: str) -> SpaceJoin:
        raise self._missing("join_space")

    def revoke(self, installation: Installation) -> None:
        raise self._missing("revoke")

    def authorizing_identity(self, installation: Installation) -> str | None:
        return None

    def adapter_env(self, installation: Installation) -> dict[str, str]:
        raise self._missing("adapter_env")

    def adopt_token(self, state: SetupState, vault_item_id: str) -> Installation:
        raise self._missing("adopt_token")

    def has_config_credential(self, workspace: str) -> bool:
        return False

    def accept_config_credential(self, state: SetupState, vault_item_id: str, refresh_vault_item_id: str | None) -> str | None:
        return None

    def accept_app_level_credential(self, state: SetupState, vault_item_id: str) -> None:
        raise self._missing("accept_app_level_credential")

    def manual_step_action(self, state: SetupState, step: ProviderCapability) -> NextAction:
        return NextAction(kind=NextActionKind.button, action_id=step.value)

    def parse_owner_identity(self, raw: str) -> str | None:
        return raw.strip() or None

    def update_identity(self, installation: Installation) -> IdentityUpdate:
        raise self._missing("update_identity")

    def store_icon(self, bot: str, png: bytes) -> None:
        raise self._missing("store_icon")

    def new_install_config(self, installation: Installation, owner: str) -> dict[str, Any]:
        return {}

    def open_owner_dm(self, installation: Installation, owner: str) -> str:
        raise self._missing("open_owner_dm")

    def is_direct_space(self, space_id: str) -> bool:
        return False

    def list_people(self, installation: Installation, query: str, cursor: str) -> PeoplePage:
        raise self._missing("list_people")

    def people_names(self, installation: Installation, member_ids: list[str]) -> dict[str, str]:
        raise self._missing("people_names")

    def leave_space(self, installation: Installation, space_id: str) -> SpaceLeaveOutcome:
        raise self._missing("leave_space")


SETUP_CAPABILITIES = (
    ProviderCapability.set_icon,
    ProviderCapability.app_level_credential,
    ProviderCapability.gateway_redirect,
)

CREDENTIAL_STEPS = frozenset({ProviderCapability.app_level_credential})

FIX_FOR_ERROR: dict[SetupErrorCode, FixAction] = {
    SetupErrorCode.credential_rejected: FixAction.reenter_credential,
    SetupErrorCode.credential_expired: FixAction.reenter_credential,
    SetupErrorCode.app_create_failed: FixAction.retry,
    SetupErrorCode.allow_denied: FixAction.restart_allow,
    SetupErrorCode.install_failed: FixAction.retry,
    SetupErrorCode.provider_unreachable: FixAction.retry,
}

SLACK_UNVERIFIED_DEFAULT = CapabilityMode.guided

SLACK_IDENTITY_POLICY = IdentityPolicy(
    app_name_max=35, display_name_max=80, username_max=21, avatar_max_bytes=2 * 1024 * 1024, avatar_min_px=512,
)

SLACK_CAPABILITIES = Capabilities(
    provider_id="slack",
    requires_config_credential=True,
    creates_app=True,
    capabilities=[
        CapabilityEntry(capability=ProviderCapability.set_icon, mode=SLACK_UNVERIFIED_DEFAULT),
        CapabilityEntry(capability=ProviderCapability.app_level_credential, mode=SLACK_UNVERIFIED_DEFAULT),
        CapabilityEntry(capability=ProviderCapability.gateway_redirect, mode=SLACK_UNVERIFIED_DEFAULT),
        CapabilityEntry(capability=ProviderCapability.unattended_refresh, mode=SLACK_UNVERIFIED_DEFAULT),
        CapabilityEntry(capability=ProviderCapability.join_public_space, mode=CapabilityMode.automatic),
        CapabilityEntry(capability=ProviderCapability.join_private_space, mode=CapabilityMode.guided),
    ],
    identity_policy=SLACK_IDENTITY_POLICY,
)


@dataclass(frozen=True)
class SetupEvent:
    kind: SetupEventKind
    app_id: str | None = None
    installation_id: str | None = None
    manual_step: ProviderCapability | None = None
    error: SetupErrorCode | None = None
    authorize_link: str | None = None
    owner_pending: bool = False


def _pending_manual(caps: Capabilities, done: list[ProviderCapability]) -> ProviderCapability | None:
    for entry in caps.capabilities:
        if entry.capability in SETUP_CAPABILITIES and entry.mode is CapabilityMode.guided and entry.capability not in done:
            return entry.capability
    return None


def _action_for(step: SetupStep, manual: ProviderCapability | None, link: str | None, error: SetupError | None) -> NextAction:
    if step is SetupStep.needs_credential:
        return NextAction(kind=NextActionKind.paste_credential, action_id="config_credential")
    if step is SetupStep.needs_manual_step and manual is not None:
        return NextAction(kind=NextActionKind.button, action_id=manual.value)
    if step is SetupStep.needs_allow:
        return NextAction(kind=NextActionKind.open_link, action_id="allow", link=link)
    if step is SetupStep.needs_owner:
        return NextAction(kind=NextActionKind.enter_text, action_id=OWNER_FIELD_ID)
    if step is SetupStep.error and error is not None:
        return NextAction(kind=NextActionKind.button, action_id=error.fix.value)
    return NextAction(kind=NextActionKind.none, action_id="none")


def initial_state(bot: str, provider_id: str, workspace: str, now: float) -> SetupState:
    return SetupState(
        bot=bot, provider_id=provider_id, workspace=workspace, step=SetupStep.not_started, revision=0,
        next_action=_action_for(SetupStep.not_started, None, None, None), updated_at=now,
    )


def _after_app(caps: Capabilities, done: list[ProviderCapability]) -> SetupStep:
    return SetupStep.needs_manual_step if _pending_manual(caps, done) else SetupStep.needs_allow


def _target(state: SetupState, event: SetupEvent, caps: Capabilities, credential_on_file: bool) -> tuple[SetupStep, dict] | None:
    step, kind = state.step, event.kind
    if kind is SetupEventKind.revoked:
        return SetupStep.revoked, {
            "app_id": None, "installation_id": None, "manual_steps_done": [], "resume_step": None, "error": None}
    if kind is SetupEventKind.failed and event.error is not None and step not in (SetupStep.ready, SetupStep.revoked):
        return SetupStep.error, {"resume_step": step, "error": SetupError(code=event.error, fix=FIX_FOR_ERROR[event.error])}
    if kind is SetupEventKind.retry and step is SetupStep.error:
        resume = state.resume_step or SetupStep.not_started
        config_credential_failed = state.error and state.error.fix is FixAction.reenter_credential \
            and state.resume_step is not SetupStep.needs_manual_step
        if config_credential_failed and caps.requires_config_credential:
            resume = SetupStep.needs_credential
        return resume, {"resume_step": None, "error": None}
    if kind is SetupEventKind.begin and step in (SetupStep.not_started, SetupStep.revoked):
        if caps.requires_config_credential and not credential_on_file:
            return SetupStep.needs_credential, {}
        return (SetupStep.creating_app if caps.creates_app else SetupStep.needs_allow), {}
    if kind is SetupEventKind.credential_saved and step is SetupStep.needs_credential:
        if state.app_id or not caps.creates_app:
            return _after_app(caps, state.manual_steps_done), {}
        return SetupStep.creating_app, {}
    if kind is SetupEventKind.app_created and step is SetupStep.creating_app and event.app_id:
        return _after_app(caps, state.manual_steps_done), {"app_id": state.app_id or event.app_id}
    if kind is SetupEventKind.manual_step_done and step is SetupStep.needs_manual_step and event.manual_step:
        done = state.manual_steps_done if event.manual_step in state.manual_steps_done else [*state.manual_steps_done, event.manual_step]
        return _after_app(caps, done), {"manual_steps_done": done}
    if kind is SetupEventKind.allow_granted and step is SetupStep.needs_allow and event.installation_id:
        target = SetupStep.needs_owner if event.owner_pending else SetupStep.installing
        return target, {"installation_id": state.installation_id or event.installation_id}
    if kind is SetupEventKind.owner_confirmed and step is SetupStep.needs_owner:
        return SetupStep.installing, {}
    if kind is SetupEventKind.installed and step is SetupStep.installing:
        return SetupStep.ready, {}
    return None


def advance(state: SetupState, event: SetupEvent, caps: Capabilities, now: float, *,
            credential_on_file: bool = False) -> SetupState:
    target = _target(state, event, caps, credential_on_file)
    if target is None:
        return state
    step, changes = target
    merged = state.model_copy(update={"step": step, **changes})
    if merged == state:
        return state
    if step is SetupStep.creating_app and merged.app_id:
        merged = merged.model_copy(update={"step": _after_app(caps, merged.manual_steps_done)})
    link = event.authorize_link if event.authorize_link else (state.next_action.link if state.next_action.kind is NextActionKind.open_link else None)
    action = _action_for(merged.step, _pending_manual(caps, merged.manual_steps_done), link, merged.error)
    fallback = NextAction(kind=NextActionKind.paste_credential, action_id="bot_token") if merged.step is SetupStep.needs_allow else None
    return merged.model_copy(update={"next_action": action, "fallback_action": fallback, "revision": state.revision + 1, "updated_at": now})


def needs_app_creation(state: SetupState) -> bool:
    return state.step is SetupStep.creating_app and state.app_id is None


SetupKey = tuple[str, str, str]


def setup_key(state: SetupState) -> SetupKey:
    return state.bot, state.provider_id, state.workspace


class SetupStore(Protocol):
    def load(self, key: SetupKey) -> SetupState | None: ...

    def save(self, state: SetupState, expected_revision: int) -> None: ...
