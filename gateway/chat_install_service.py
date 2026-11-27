from __future__ import annotations

import logging
import time
from collections.abc import Callable
from contextlib import AbstractContextManager
from dataclasses import dataclass
from enum import Enum
from typing import Any, Protocol
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

from gateway.audience import AudiencePolicy, AudiencePolicyKind
from gateway.chat_audience import AudienceSettings, read_audience, read_home, write_audience, write_home
from gateway.chat_install_store import ChatInstallStore
from tools.connectors.app_scheme import AppScheme
from tools.image_asset import ImageAssetError, decode_image
from tui_gateway.chat_install import (
    CREDENTIAL_STEPS,
    OWNER_DM_HOME_NAME,
    ChatProvider,
    ChatProviderError,
    IdentityUpdate,
    PeoplePage,
    ProviderNotImplemented,
    SetupEvent,
    SetupKey,
    SpaceJoin,
    StaleRevision,
    advance as pure_advance,
    initial_state,
    needs_app_creation,
    reopen_manual_steps,
    setup_key,
)
from tui_gateway.chat_providers import UnknownProvider, registered_provider_ids
from tui_gateway.contracts.chat_provider import (
    AdapterFailure,
    AdapterState,
    AdapterStatus,
    Binding,
    Capabilities,
    ChannelAccess,
    ChatRpcErrorReason,
    Installation,
    NextAction,
    NextActionKind,
    ProviderCapability,
    ReportDestination,
    ReportDestinationKind,
    SetupErrorCode,
    SetupEventKind,
    SetupState,
    SetupStep,
    SpaceLeaveOutcome,
    SpaceRef,
)

logger = logging.getLogger(__name__)

CLIENT_EVENTS = frozenset({
    SetupEventKind.credential_saved, SetupEventKind.manual_step_done, SetupEventKind.allow_granted,
    SetupEventKind.owner_confirmed, SetupEventKind.retry, SetupEventKind.reopen_step,
})
CREDENTIAL_FAILURES = frozenset({SetupErrorCode.credential_rejected, SetupErrorCode.credential_expired})
SETTLE_ATTEMPTS = 3
SET_PUBLIC_URL_ACTION = NextAction(kind=NextActionKind.button, action_id="set_public_url")


class ReloadOutcome(Enum):
    live = "live"
    restarting = "restarting"
    not_started = "not_started"


class AdapterControl(Protocol):
    def apply_env(self, profile: str, platform_id: str, env: dict[str, str], clear: list[str]) -> None: ...

    def reload(self, profile: str) -> ReloadOutcome: ...

    def seed_config(self, profile: str, defaults: dict[str, Any]) -> None: ...

    def is_live(self, profile: str, platform_id: str) -> bool: ...


class GatewayReason(Enum):
    owner_only = "owner_only"
    needs_public_url = "needs_public_url"
    invalid_event = "invalid_event"
    invalid_input = "invalid_input"
    invalid_image = "invalid_image"
    not_joined = "not_joined"
    provider_failed = "provider_failed"


class ChatServiceError(Exception):
    def __init__(self, reason: ChatRpcErrorReason | GatewayReason, state: SetupState | None = None, fix: NextAction | None = None):
        super().__init__(reason.value)
        self.reason, self.state, self.fix = reason, state, fix


class RedirectOutcome(Enum):
    completed = "completed"
    denied = "denied"
    rejected = "rejected"
    failed = "failed"


@dataclass(frozen=True)
class ChatInstallService:
    store: ChatInstallStore
    provider_for: Callable[[str], ChatProvider]
    control: AdapterControl
    public_url: Callable[[], str | None]
    bot_scope: Callable[[str], AbstractContextManager[object]]
    clock: Callable[[], float] = time.time

    def _provider(self, provider_id: str) -> ChatProvider:
        try:
            return self.provider_for(provider_id)
        except UnknownProvider:
            raise ChatServiceError(ChatRpcErrorReason.provider_unknown) from None

    def _current(self, bot: str, provider_id: str, workspace: str) -> SetupState:
        return self.store.load((bot, provider_id, workspace)) or initial_state(bot, provider_id, workspace, self.clock())

    def _apply(self, provider: ChatProvider, state: SetupState, event: SetupEvent) -> SetupState:
        caps = provider.capabilities(state.workspace)
        on_file = event.kind is SetupEventKind.begin and caps.requires_config_credential \
            and provider.has_config_credential(state.workspace)
        new = pure_advance(state, event, caps, self.clock(), credential_on_file=on_file)
        if new is not state:
            new = self._with_manual_action(provider, new)
            self.store.save(new, state.revision)
        return new

    @staticmethod
    def _with_manual_action(provider: ChatProvider, state: SetupState) -> SetupState:
        if state.step is not SetupStep.needs_manual_step:
            return state
        step = ProviderCapability(state.next_action.action_id)
        return state.model_copy(update={"next_action": provider.manual_step_action(state, step)})

    def _reopen_unmet(self, provider: ChatProvider, state: SetupState, *, rejected: bool = False) -> SetupState:
        if state.step is not SetupStep.needs_allow:
            return state
        unmet = frozenset(state.manual_steps_done) - provider.satisfied_manual_steps(state)
        if not unmet:
            return state
        new = reopen_manual_steps(state, provider.capabilities(state.workspace), unmet, self.clock(), rejected=rejected)
        if new is state:
            return state
        new = self._with_manual_action(provider, new)
        self.store.save(new, state.revision)
        return new

    def _fail(self, provider: ChatProvider, state: SetupState, code: SetupErrorCode, *, reason: str | None = None,
              permissions: tuple[str, ...] = (), retry_after_seconds: int | None = None) -> SetupState:
        return self._apply(provider, state, SetupEvent(
            kind=SetupEventKind.failed, error=code, error_reason=reason, error_permissions=permissions,
            retry_after_seconds=retry_after_seconds))

    def _fail_from(self, provider: ChatProvider, state: SetupState, exc: Exception) -> SetupState:
        code = exc.code if isinstance(getattr(exc, "code", None), SetupErrorCode) else SetupErrorCode.install_failed
        retry_after = getattr(exc, "retry_after_seconds", None)
        return self._fail(provider, state, code, reason=getattr(exc, "reason", None),
                          permissions=tuple(getattr(exc, "permissions", ())),
                          retry_after_seconds=retry_after if isinstance(retry_after, int) else None)

    def _install_in_place(self, provider: ChatProvider, state: SetupState) -> SetupState | None:
        try:
            installation = provider.install_in_place(state)
        except StaleRevision:
            raise
        except Exception as exc:  # health: allow BLE001 -- provider and adapter errors carry provider text, so only the exception type is logged
            logger.warning("chat install in place failed provider=%s error=%s", state.provider_id, type(exc).__name__)
            return self._fail_from(provider, state, exc)
        if installation is None:
            return None
        return self._complete(provider, state, installation, owner_optional=True)

    @staticmethod
    def _with_state(link: str, nonce: str) -> str:
        parts = urlsplit(link)
        query = [(k, v) for k, v in parse_qsl(parts.query, keep_blank_values=True) if k != "state"]
        query.append(("state", nonce))
        return urlunsplit(parts._replace(query=urlencode(query)))

    def _with_nonce(self, link: str, key: SetupKey, app_scheme: AppScheme) -> str:
        return self._with_state(link, self.store.issue_nonce(key, app_scheme))

    def _allow_state(self, state: SetupState, link: str) -> SetupState:
        action = NextAction(kind=NextActionKind.open_link, action_id="allow", link=link)
        return state.model_copy(update={"next_action": action, "revision": state.revision + 1, "updated_at": self.clock()})

    def _attach_link(self, state: SetupState, link: str) -> SetupState:
        new = self._allow_state(state, link)
        self.store.save(new, state.revision)
        return new

    def _renew_dead_allow_link(self, state: SetupState) -> SetupState:
        if state.step is not SetupStep.needs_allow:
            return state
        key = setup_key(state)
        action = state.next_action
        base = action.link if action.kind is NextActionKind.open_link and action.link else self.store.authorize_link(key)
        if base is None:
            return state
        nonce = dict(parse_qsl(urlsplit(base).query, keep_blank_values=True)).get("state")
        if nonce and self.store.nonce_live(nonce, key):
            return state
        return self.store.save_with_nonce(key, state.revision, lambda fresh: self._allow_state(state, self._with_state(base, fresh)))

    def _authorize_base(self, provider: ChatProvider, state: SetupState) -> str:
        key = setup_key(state)
        if base := self.store.authorize_link(key):
            return base
        base = provider.begin_install(state, self.store.config_item(key)).authorize_link
        self.store.set_authorize_link(key, base)
        return base

    def _issue_link(self, provider: ChatProvider, state: SetupState, app_scheme: AppScheme) -> SetupState:
        try:
            return self._attach_link(
                state, self._with_nonce(self._authorize_base(provider, state), setup_key(state), app_scheme))
        except StaleRevision:
            raise
        except Exception as exc:  # health: allow BLE001 -- provider and adapter errors carry provider text, so only the exception type is logged
            logger.warning("chat install link failed provider=%s error=%s", state.provider_id, type(exc).__name__)
            return self._fail(provider, state, self._creation_error_code(exc))

    def _drive(self, provider: ChatProvider, state: SetupState, app_scheme: AppScheme) -> SetupState:
        key = setup_key(state)
        if needs_app_creation(state):
            try:
                created = provider.begin_install(state, self.store.config_item(key))
            except Exception as exc:  # health: allow BLE001 -- provider and adapter errors carry provider text, so only the exception type is logged
                logger.warning("chat install app creation failed provider=%s error=%s", state.provider_id, type(exc).__name__)
                return self._fail(provider, state, self._creation_error_code(exc))
            self.store.set_authorize_link(key, created.authorize_link)
            state = self._apply(provider, state, SetupEvent(
                kind=SetupEventKind.app_created, app_id=created.app_id,
                authorize_link=self._with_nonce(created.authorize_link, key, app_scheme)))
        if state.step is SetupStep.needs_allow and (placed := self._install_in_place(provider, state)) is not None:
            return placed
        if state.step is SetupStep.needs_allow and (state.next_action.link is None or state.next_action.kind is not NextActionKind.open_link):
            state = self._issue_link(provider, state, app_scheme)
        if state.step is SetupStep.needs_owner:
            state = self._confirm_known_owner(provider, state)
        if state.step is SetupStep.installing:
            state = self._finish(provider, state)
        return state

    def provider_capabilities(self) -> list[Capabilities]:
        return [self._provider(provider_id).capabilities() for provider_id in registered_provider_ids()]

    def status(self, bot: str, provider_id: str, workspace: str) -> tuple[SetupState, Installation | None]:
        provider = self._provider(provider_id)
        state = self._current(bot, provider_id, workspace)
        if (connected := self._as_connected(provider, state)) is not None:
            return connected, None
        try:
            state = self._renew_dead_allow_link(self._reopen_unmet(provider, state))
        except StaleRevision:
            state = self._current(bot, provider_id, workspace)
        state = self._with_manual_action(provider, state)
        return state, self._installation_of(state)

    def _as_connected(self, provider: ChatProvider, state: SetupState) -> SetupState | None:
        if state.step is SetupStep.ready or not provider.per_bot_adapter:
            return None
        try:
            live = self.control.is_live(state.bot, state.provider_id)
        except Exception as exc:  # health: allow BLE001 -- adapter errors carry provider text, so only the exception type is logged
            logger.warning("chat install live check failed provider=%s error=%s", state.provider_id, type(exc).__name__)
            return None
        if not live:
            return None
        return state.model_copy(update={
            "step": SetupStep.ready, "next_action": NextAction(kind=NextActionKind.none, action_id="none"),
            "error": None, "resume_step": None})

    def _installation_of(self, state: SetupState) -> Installation | None:
        if state.installation_id is None or state.step is not SetupStep.ready:
            return None
        return self.store.installation(state.installation_id)

    def live_adapter(self, installation: Installation | None) -> AdapterStatus | None:
        if installation is None:
            return None
        provider = self._provider(installation.provider_id)
        try:
            return provider.adapter_status(installation)
        except Exception as exc:  # health: allow BLE001 -- adapter errors carry provider text, so only the exception type is logged
            logger.warning("chat adapter status failed provider=%s error=%s", installation.provider_id, type(exc).__name__)
            return AdapterStatus(state=AdapterState.failed, reason=AdapterFailure.adapter_offline)

    def live_channels(self, installation: Installation | None) -> list[ChannelAccess] | None:
        if installation is None:
            return None
        provider = self._provider(installation.provider_id)
        try:
            return provider.channel_access(installation)
        except Exception as exc:  # health: allow BLE001 -- adapter errors carry provider text, so only the exception type is logged
            logger.warning("chat channel check failed provider=%s error=%s", installation.provider_id, type(exc).__name__)
            return None

    def reconnect(self, bot: str, provider_id: str, workspace: str) -> tuple[SetupState, Installation, AdapterStatus]:
        provider, state, installation = self._installed(bot, provider_id, workspace)
        return state, installation, self._call(state, lambda: provider.reconnect_adapter(installation))

    def begin(self, bot: str, provider_id: str, workspace: str,
              app_scheme: AppScheme = AppScheme.release) -> tuple[SetupState, Installation | None]:
        provider = self._provider(provider_id)
        state = self._current(bot, provider_id, workspace)
        if state.step is SetupStep.ready:
            return state, self._installation_of(state)
        if (connected := self._as_connected(provider, state)) is not None:
            return connected, None
        if provider.needs_public_url and not (self.public_url() or "").startswith("https://"):
            raise ChatServiceError(GatewayReason.needs_public_url, state, SET_PUBLIC_URL_ACTION)
        try:
            state = self._reopen_unmet(provider, self._apply(provider, state, SetupEvent(kind=SetupEventKind.begin)))
            if state.step is SetupStep.needs_allow and state.next_action.link:
                state = self._attach_link(
                    state, self._with_nonce(self._authorize_base(provider, state), setup_key(state), app_scheme))
            else:
                state = self._drive(provider, state, app_scheme)
        except StaleRevision:
            raise ChatServiceError(ChatRpcErrorReason.stale_revision, self._current(bot, provider_id, workspace)) from None
        return state, self._installation_of(state)

    def advance(self, bot: str, provider_id: str, workspace: str, event: SetupEventKind, expected_revision: int,
                manual_step=None, vault_item_id: str | None = None, refresh_vault_item_id: str | None = None,
                owner_member_id: str | None = None,
                app_scheme: AppScheme = AppScheme.release) -> tuple[SetupState, Installation | None]:
        provider = self._provider(provider_id)
        state = self._current(bot, provider_id, workspace)
        if state.revision != expected_revision:
            raise ChatServiceError(ChatRpcErrorReason.stale_revision, state)
        if event is SetupEventKind.begin:
            return self.begin(bot, provider_id, workspace, app_scheme)
        if event is SetupEventKind.revoked:
            return self.revoke(bot, provider_id, workspace)
        if event not in CLIENT_EVENTS:
            raise ChatServiceError(GatewayReason.invalid_event, state)
        try:
            if event is SetupEventKind.allow_granted:
                new = self._adopt(provider, state, vault_item_id)
            elif event is SetupEventKind.owner_confirmed:
                new = self._confirm_owner(provider, state, owner_member_id)
            elif event is SetupEventKind.reopen_step:
                new = self._reopen(provider, state, manual_step, app_scheme)
            else:
                new = self._client_event(provider, state, event, manual_step, vault_item_id, refresh_vault_item_id, app_scheme)
        except StaleRevision:
            raise ChatServiceError(ChatRpcErrorReason.stale_revision, self._current(bot, provider_id, workspace)) from None
        if new is state:
            raise ChatServiceError(GatewayReason.invalid_event, state)
        return new, self._installation_of(new)

    def _reopen(self, provider: ChatProvider, state: SetupState, manual_step: ProviderCapability | None,
                app_scheme: AppScheme) -> SetupState:
        if manual_step is not None:
            return self._apply(provider, state, SetupEvent(kind=SetupEventKind.reopen_step, manual_step=manual_step))
        if state.step is SetupStep.needs_allow:
            return self._issue_link(provider, state, app_scheme)
        if state.step is SetupStep.error and state.resume_step is SetupStep.needs_allow:
            return self._drive(provider, self._apply(provider, state, SetupEvent(kind=SetupEventKind.retry)), app_scheme)
        return state

    def _client_event(self, provider, state, event, manual_step, vault_item_id, refresh_vault_item_id,
                      app_scheme: AppScheme) -> SetupState:
        if event is SetupEventKind.manual_step_done and manual_step is None and state.step is SetupStep.needs_manual_step:
            manual_step = ProviderCapability(state.next_action.action_id)
        if event is SetupEventKind.manual_step_done and manual_step in CREDENTIAL_STEPS:
            return self._credential_step(provider, state, manual_step, vault_item_id, app_scheme)
        new = self._apply(provider, state, SetupEvent(kind=event, manual_step=manual_step))
        if new is state:
            return state
        if event is SetupEventKind.credential_saved and vault_item_id:
            try:
                vault_item_id = provider.accept_config_credential(new, vault_item_id, refresh_vault_item_id) or vault_item_id
            except Exception as exc:  # health: allow BLE001 -- provider errors carry provider text, so only the exception type is logged
                logger.warning("chat install credential rejected provider=%s error=%s", state.provider_id, type(exc).__name__)
                return self._fail(provider, new, self._error_code(exc))
            self.store.set_config_item(setup_key(new), vault_item_id)
        return self._drive(provider, self._reopen_unmet(provider, new), app_scheme)

    @staticmethod
    def _error_code(exc: Exception) -> SetupErrorCode:
        code = getattr(exc, "code", None)
        return code if isinstance(code, SetupErrorCode) else SetupErrorCode.credential_rejected

    @staticmethod
    def _creation_error_code(exc: Exception) -> SetupErrorCode:
        code = getattr(exc, "code", None)
        return code if code in CREDENTIAL_FAILURES else SetupErrorCode.app_create_failed

    def _credential_step(self, provider: ChatProvider, state: SetupState, step, vault_item_id: str | None,
                         app_scheme: AppScheme) -> SetupState:
        if state.step is not SetupStep.needs_manual_step:
            return state
        if not vault_item_id:
            raise ChatServiceError(GatewayReason.invalid_event, state)
        try:
            provider.accept_app_level_credential(state, vault_item_id)
        except Exception as exc:  # health: allow BLE001 -- provider errors carry provider text, so only the exception type is logged
            logger.warning("chat install app credential rejected provider=%s error=%s", state.provider_id, type(exc).__name__)
            return self._fail(provider, state, self._error_code(exc))
        new = self._apply(provider, state, SetupEvent(kind=SetupEventKind.manual_step_done, manual_step=step))
        return self._drive(provider, new, app_scheme)

    def _adopt(self, provider: ChatProvider, state: SetupState, vault_item_id: str | None) -> SetupState:
        if state.step is not SetupStep.needs_allow or not vault_item_id:
            return state
        if (reopened := self._reopen_unmet(provider, state, rejected=True)) is not state:
            return reopened
        try:
            installation = provider.adopt_token(state, vault_item_id)
        except Exception as exc:  # health: allow BLE001 -- provider and adapter errors carry provider text, so only the exception type is logged
            logger.warning("chat install adopt failed provider=%s error=%s", state.provider_id, type(exc).__name__)
            return self._fail(provider, state, SetupErrorCode.install_failed)
        return self._complete(provider, state, installation, owner_optional=True)

    def _confirm_owner(self, provider: ChatProvider, state: SetupState, raw: str | None) -> SetupState:
        owner = provider.parse_owner_identity(raw or "")
        if state.step is not SetupStep.needs_owner or not owner or state.installation_id is None:
            return state
        self.store.set_owner(state.installation_id, owner)
        state = self._apply(provider, state, SetupEvent(kind=SetupEventKind.owner_confirmed))
        return self._finish(provider, state)

    def _confirm_known_owner(self, provider: ChatProvider, state: SetupState) -> SetupState:
        installation = self.store.installation(state.installation_id) if state.installation_id else None
        if installation is None:
            return state
        try:
            owner = provider.authorizing_identity(installation)
        except Exception as exc:  # health: allow BLE001 -- provider errors carry provider text, so only the exception type is logged
            logger.warning("chat install owner lookup failed provider=%s error=%s", state.provider_id, type(exc).__name__)
            return state
        return self._confirm_owner(provider, state, owner)

    def _complete(self, provider: ChatProvider, state: SetupState, installation: Installation,
                  owner_optional: bool = False) -> SetupState:
        try:
            owner = provider.authorizing_identity(installation)
            if not owner and not owner_optional:
                return self._fail(provider, state, SetupErrorCode.install_failed)
            env_keys = [*provider.adapter_env(installation), *([provider.allowed_users_env] if provider.allowed_users_env else [])] \
                if provider.per_bot_adapter else []
            self.store.save_installation(installation, env_keys, owner or "")
        except StaleRevision:
            raise
        except Exception as exc:  # health: allow BLE001 -- provider and adapter errors carry provider text, so only the exception type is logged
            logger.warning("chat install persist failed provider=%s error=%s", state.provider_id, type(exc).__name__)
            return self._fail(provider, state, SetupErrorCode.install_failed)
        state = self._apply(provider, state, SetupEvent(
            kind=SetupEventKind.allow_granted, installation_id=installation.id, owner_pending=not owner))
        return self._finish(provider, state) if state.step is SetupStep.installing else state

    def _finish(self, provider: ChatProvider, state: SetupState) -> SetupState:
        installation = self.store.installation(state.installation_id) if state.installation_id else None
        owner = self.store.owner_id(installation.id) if installation else None
        if installation is None or not owner:
            return self._fail(provider, state, SetupErrorCode.install_failed)
        try:
            defaults = provider.new_install_config(installation, owner)
            if defaults:
                self.control.seed_config(state.bot, defaults)
        except Exception as exc:  # health: allow BLE001 -- provider and adapter errors carry provider text, so only the exception type is logged
            logger.warning("chat install defaults failed provider=%s error=%s", state.provider_id, type(exc).__name__)
            return self._fail(provider, state, SetupErrorCode.install_failed)
        try:
            outcome = self._start_adapter(provider, state, installation, owner)
        except Exception as exc:  # health: allow BLE001 -- provider and adapter errors carry provider text, so only the exception type is logged
            logger.warning("chat install adapter start failed provider=%s error=%s", state.provider_id, type(exc).__name__)
            return self._fail_from(provider, state, exc)
        if outcome is ReloadOutcome.not_started:
            logger.warning("chat install adapter not started provider=%s", state.provider_id)
            return self._fail(provider, state, SetupErrorCode.install_failed)
        return self._apply(provider, state, SetupEvent(kind=SetupEventKind.installed))

    def _start_adapter(self, provider: ChatProvider, state: SetupState, installation: Installation, owner: str) -> ReloadOutcome:
        if not provider.per_bot_adapter:
            provider.apply_owner(installation, owner)
            return ReloadOutcome.live
        env = dict(provider.adapter_env(installation))
        if provider.allowed_users_env:
            env[provider.allowed_users_env] = owner
        self.control.apply_env(state.bot, provider.provider_id, env, [])
        return self.control.reload(state.bot)

    def complete_redirect(self, raw_state: str, code: str | None, error: str | None) -> tuple[RedirectOutcome, AppScheme]:
        issued = self.store.consume_nonce(raw_state) if raw_state else None
        if issued is None:
            return RedirectOutcome.rejected, AppScheme.release
        key, app_scheme = issued
        try:
            with self.bot_scope(key[0]):
                return self._finish_redirect(key, code, error), app_scheme
        except (StaleRevision, ChatServiceError) as exc:
            logger.warning("chat install redirect rejected provider=%s error=%s", key[1], type(exc).__name__)
            return RedirectOutcome.rejected, app_scheme
        finally:
            self.store.release_nonce(raw_state)

    def _finish_redirect(self, key: SetupKey, code: str | None, error: str | None) -> RedirectOutcome:
        provider = self._provider(key[1])
        state = self.store.load(key)
        if state is None:
            return RedirectOutcome.rejected
        if state.step is SetupStep.ready and self._installation_of(state) is not None:
            return RedirectOutcome.completed
        if state.step is not SetupStep.needs_allow:
            return RedirectOutcome.rejected
        if error:
            self._fail(provider, state, SetupErrorCode.allow_denied)
            return RedirectOutcome.denied
        if not code:
            return RedirectOutcome.rejected
        if self._reopen_unmet(provider, state, rejected=True) is not state:
            return RedirectOutcome.failed
        try:
            installation = provider.complete_install(state, code)
        except Exception as exc:  # health: allow BLE001 -- provider and adapter errors carry provider text, so only the exception type is logged
            logger.warning("chat install redirect failed provider=%s error=%s", key[1], type(exc).__name__)
            self._fail(provider, state, SetupErrorCode.install_failed)
            return RedirectOutcome.failed
        done = self._complete(provider, state, installation)
        return RedirectOutcome.failed if done.step is SetupStep.error else RedirectOutcome.completed

    def _installed(self, bot: str, provider_id: str, workspace: str) -> tuple[ChatProvider, SetupState, Installation]:
        provider = self._provider(provider_id)
        state = self._current(bot, provider_id, workspace)
        installation = self._installation_of(state)
        if installation is None:
            raise ChatServiceError(ChatRpcErrorReason.no_installation, state)
        return provider, state, installation

    def _call(self, state: SetupState, call):
        try:
            return call()
        except ProviderNotImplemented:
            raise ChatServiceError(ChatRpcErrorReason.not_implemented, state) from None
        except Exception as exc:  # health: allow BLE001 -- provider and adapter errors carry provider text, so only the exception type is logged
            logger.warning("chat provider call failed provider=%s error=%s", state.provider_id, type(exc).__name__)
            raise ChatServiceError(GatewayReason.provider_failed, state) from None

    def spaces(self, bot: str, provider_id: str, workspace: str) -> list[SpaceRef]:
        provider, state, installation = self._installed(bot, provider_id, workspace)
        return self._call(state, lambda: provider.list_spaces(installation))

    def join(self, bot: str, provider_id: str, workspace: str, space_id: str, hello: bool) -> SpaceJoin:
        provider, state, installation = self._installed(bot, provider_id, workspace)
        result = self._call(state, lambda: provider.join_space(installation, space_id))
        from tui_gateway.contracts.chat_provider import SpaceJoinOutcome
        self.store.set_binding(installation.id, space_id, bot, result.outcome is not SpaceJoinOutcome.needs_invite, hello)
        return result

    def update_identity(self, bot: str, provider_id: str, workspace: str) -> IdentityUpdate:
        provider, state, installation = self._installed(bot, provider_id, workspace)
        return self._call(state, lambda: provider.update_identity(installation))

    def bindings(self, bot: str) -> list[Binding]:
        return [row.wire() for row in self.store.bindings(bot)]

    def set_icon(self, bot: str, provider_id: str, data: str) -> None:
        provider = self._provider(provider_id)
        try:
            png, _ = decode_image(data, ("png",))
            provider.store_icon(bot, png)
        except ImageAssetError:
            raise ChatServiceError(GatewayReason.invalid_image) from None
        except ProviderNotImplemented:
            raise ChatServiceError(ChatRpcErrorReason.not_implemented) from None

    def audience(self, bot: str, provider_id: str, workspace: str) -> tuple[AudienceSettings, dict[str, str]]:
        provider, _, installation = self._installed(bot, provider_id, workspace)
        with self.bot_scope(bot):
            settings = read_audience(provider_id)
        names: dict[str, str] = {}
        if settings.policy.members:
            try:
                names = provider.people_names(installation, sorted(settings.policy.members))
            except Exception as exc:  # health: allow BLE001 -- names are cosmetic and provider text must not reach the log, so only the exception type is logged
                logger.warning("chat audience names unavailable provider=%s error=%s", provider_id, type(exc).__name__)
        return settings, names

    def set_audience(self, bot: str, provider_id: str, workspace: str, kind: AudiencePolicyKind,
                     members: list[str] | None, include_restricted: bool | None, turns_per_hour: int | None,
                     expected_revision: int) -> tuple[AudienceSettings, dict[str, str]]:
        provider, state, _ = self._installed(bot, provider_id, workspace)
        parsed = None
        if members is not None:
            checked = [provider.parse_owner_identity(member) for member in members]
            if not all(checked):
                raise ChatServiceError(GatewayReason.invalid_input, state)
            parsed = frozenset(checked)
        with self.bot_scope(bot):
            current = read_audience(provider_id)
            policy = AudiencePolicy(
                kind, current.policy.members if parsed is None else parsed,
                current.policy.include_restricted if include_restricted is None else include_restricted,
                current.policy.member_turns_per_hour if turns_per_hour is None else turns_per_hour)
            try:
                write_audience(provider_id, policy, expected_revision)
            except StaleRevision:
                raise ChatServiceError(ChatRpcErrorReason.stale_revision, state) from None
        return self.audience(bot, provider_id, workspace)

    def people(self, bot: str, provider_id: str, workspace: str, query: str, cursor: str) -> PeoplePage:
        provider, state, installation = self._installed(bot, provider_id, workspace)
        return self._call(state, lambda: provider.list_people(installation, query, cursor))

    def report(self, bot: str, provider_id: str, workspace: str) -> ReportDestination:
        provider, _, _ = self._installed(bot, provider_id, workspace)
        with self.bot_scope(bot):
            home = read_home(provider_id)
        if home is None or provider.is_direct_space(home.chat_id):
            return ReportDestination(kind=ReportDestinationKind.owner_dm)
        return ReportDestination(kind=ReportDestinationKind.space, space_id=home.chat_id, name=home.name)

    def set_report(self, bot: str, provider_id: str, workspace: str, destination: ReportDestination) -> ReportDestination:
        from gateway.config import HomeChannel, Platform
        provider, state, installation = self._installed(bot, provider_id, workspace)
        owner = self.store.owner_id(installation.id)
        if not owner:
            raise ChatServiceError(GatewayReason.invalid_event, state)
        if destination.kind is ReportDestinationKind.owner_dm:
            chat_id, name = self._call(state, lambda: provider.open_owner_dm(installation, owner)), OWNER_DM_HOME_NAME
        else:
            spaces = self._call(state, lambda: provider.list_spaces(installation))
            space = next((item for item in spaces if item.id == destination.space_id and item.joined), None)
            if space is None:
                raise ChatServiceError(GatewayReason.not_joined, state)
            chat_id, name = space.id, space.name
        home = HomeChannel(platform=Platform(provider_id), chat_id=chat_id, name=name, user_id=owner,
                           scope_id=installation.workspace_id)
        with self.bot_scope(bot):
            write_home(home)
        return self.report(bot, provider_id, workspace)

    def leave(self, bot: str, provider_id: str, workspace: str, space_id: str) -> SpaceLeaveOutcome:
        provider, state, installation = self._installed(bot, provider_id, workspace)
        outcome = self._call(state, lambda: provider.leave_space(installation, space_id))
        self.store.delete_binding(installation.id, space_id)
        self.retire_asks(bot, provider_id, installation.workspace_id, space_id)
        return outcome

    @staticmethod
    def retire_asks(bot: str, provider_id: str, scope_id: str, space_id: str) -> None:
        from gateway.desk.store import DB_NAME, DeskStore
        from hermes_cli.profiles import get_profile_dir
        home = get_profile_dir(bot)
        if (home / DB_NAME).exists():
            DeskStore(home).expire_open_asks_in(provider_id, scope_id, space_id)

    def revoke(self, bot: str, provider_id: str, workspace: str) -> tuple[SetupState, Installation | None]:
        provider = self._provider(provider_id)
        state = self._current(bot, provider_id, workspace)
        installation = self.store.installation(state.installation_id) if state.installation_id else None
        if installation is not None:
            keys = self.store.env_keys(installation.id)
            try:
                if provider.per_bot_adapter:
                    self.control.apply_env(bot, provider_id, {}, keys)
                    self.control.reload(bot)
            except Exception as exc:  # health: allow BLE001 -- provider and adapter errors carry provider text, so only the exception type is logged
                logger.warning("chat install adapter stop failed provider=%s error=%s", provider_id, type(exc).__name__)
                raise ChatServiceError(GatewayReason.provider_failed, state) from None
            self._call(state, lambda: provider.revoke(installation))
            self.store.delete_bindings(installation.id)
            self.store.mark_revoked(installation.id, self.clock())
        try:
            state = self._apply(provider, state, SetupEvent(kind=SetupEventKind.revoked))
        except StaleRevision:
            raise ChatServiceError(ChatRpcErrorReason.stale_revision, self._current(bot, provider_id, workspace)) from None
        self.store.clear_authorize_link(setup_key(state))
        return state, None

    def installation_lost(self, bot: str, provider_id: str, workspace_id: str) -> None:
        installation = self.store.installation_for_workspace(provider_id, workspace_id, bot)
        if installation is None:
            return
        state = self.store.state_for_installation(installation.id)
        keys = self.store.env_keys(installation.id)
        self.store.delete_bindings(installation.id)
        self.store.mark_revoked(installation.id, self.clock())
        try:
            with self.bot_scope(bot):
                self._release_provider_side(self._provider(provider_id), installation)
                self.control.apply_env(bot, provider_id, {}, keys)
        finally:
            if state is not None:
                self._settle_revoked(self._provider(provider_id), state)

    @staticmethod
    def _release_provider_side(provider: ChatProvider, installation: Installation) -> None:
        try:
            provider.revoke(installation)
        except Exception as exc:  # health: allow BLE001 -- provider errors carry provider text, so only the exception type is logged
            logger.warning("chat install cleanup after provider uninstall failed provider=%s error=%s",
                           installation.provider_id, type(exc).__name__)

    def _settle_revoked(self, provider: ChatProvider, state: SetupState) -> None:
        for _ in range(SETTLE_ATTEMPTS):
            try:
                settled = self._apply(provider, state, SetupEvent(kind=SetupEventKind.revoked))
            except StaleRevision:
                state = self.store.load(setup_key(state)) or state
                continue
            self.store.clear_authorize_link(setup_key(settled))
            return
        logger.warning("chat install state not settled after provider uninstall provider=%s", state.provider_id)


@dataclass(frozen=True)
class BindingChange:
    installation: Installation
    changed: bool
    hello_due: bool


def bot_joined(store: ChatInstallStore, bot: str, provider_id: str, workspace_id: str, space_id: str) -> BindingChange | None:
    installation = store.installation_for_workspace(provider_id, workspace_id, bot)
    row = store.binding(installation.id, space_id) if installation else None
    if installation is None or row is None:
        return None
    changed = store.set_live(installation.id, space_id, True)
    return BindingChange(installation, changed, row.hello_requested and store.claim_hello(installation.id, space_id))


def bot_left(store: ChatInstallStore, bot: str, provider_id: str, workspace_id: str, space_id: str) -> BindingChange | None:
    installation = store.installation_for_workspace(provider_id, workspace_id, bot)
    if installation is None or store.binding(installation.id, space_id) is None:
        return None
    return BindingChange(installation, store.set_live(installation.id, space_id, False), False)


def pending_welcome(store: ChatInstallStore, bot: str, provider_id: str, workspace_id: str) -> tuple[Installation, str] | None:
    installation = store.installation_for_workspace(provider_id, workspace_id, bot)
    owner = store.owner_id(installation.id) if installation else None
    if installation is None or not owner or not store.claim_welcome(installation.id):
        return None
    return installation, owner
