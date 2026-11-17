from __future__ import annotations

import logging
import time
from collections.abc import Callable
from dataclasses import dataclass
from enum import Enum
from typing import Protocol
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

from gateway.chat_install_store import ChatInstallStore
from tui_gateway.chat_install import (
    ChatProvider,
    ChatProviderError,
    ProviderNotImplemented,
    SetupEvent,
    SetupKey,
    SpaceJoin,
    StaleRevision,
    advance as pure_advance,
    initial_state,
    needs_app_creation,
    setup_key,
)
from tui_gateway.chat_providers import UnknownProvider
from tui_gateway.contracts.chat_provider import (
    Binding,
    ChatRpcErrorReason,
    Installation,
    NextAction,
    NextActionKind,
    SetupErrorCode,
    SetupEventKind,
    SetupState,
    SetupStep,
    SpaceRef,
)

logger = logging.getLogger(__name__)

CLIENT_EVENTS = frozenset({
    SetupEventKind.credential_saved, SetupEventKind.manual_step_done, SetupEventKind.allow_granted, SetupEventKind.retry,
})
SET_PUBLIC_URL_ACTION = NextAction(kind=NextActionKind.button, action_id="set_public_url")


class AdapterControl(Protocol):
    def apply_env(self, profile: str, platform_id: str, env: dict[str, str], clear: list[str]) -> None: ...

    def reload(self, profile: str) -> None: ...


class ChatServiceError(Exception):
    def __init__(self, reason: ChatRpcErrorReason, state: SetupState | None = None, fix: NextAction | None = None):
        super().__init__(reason.value)
        self.reason, self.state, self.fix = reason, state, fix


class RedirectOutcome(Enum):
    completed = "completed"
    denied = "denied"
    rejected = "rejected"


@dataclass(frozen=True)
class ChatInstallService:
    store: ChatInstallStore
    provider_for: Callable[[str], ChatProvider]
    control: AdapterControl
    public_url: Callable[[], str | None]
    clock: Callable[[], float] = time.time

    def _provider(self, provider_id: str) -> ChatProvider:
        try:
            return self.provider_for(provider_id)
        except UnknownProvider:
            raise ChatServiceError(ChatRpcErrorReason.provider_unknown) from None

    def _current(self, bot: str, provider_id: str, workspace: str) -> SetupState:
        return self.store.load((bot, provider_id, workspace)) or initial_state(bot, provider_id, workspace, self.clock())

    def _apply(self, provider: ChatProvider, state: SetupState, event: SetupEvent) -> SetupState:
        new = pure_advance(state, event, provider.capabilities(), self.clock())
        if new is not state:
            self.store.save(new, state.revision)
        return new

    def _fail(self, provider: ChatProvider, state: SetupState, code: SetupErrorCode) -> SetupState:
        return self._apply(provider, state, SetupEvent(kind=SetupEventKind.failed, error=code))

    def _with_nonce(self, link: str, key: SetupKey) -> str:
        parts = urlsplit(link)
        query = [(k, v) for k, v in parse_qsl(parts.query, keep_blank_values=True) if k != "state"]
        query.append(("state", self.store.issue_nonce(key)))
        return urlunsplit(parts._replace(query=urlencode(query)))

    def _attach_link(self, state: SetupState, link: str) -> SetupState:
        action = NextAction(kind=NextActionKind.open_link, action_id="allow", link=link)
        new = state.model_copy(update={"next_action": action, "revision": state.revision + 1, "updated_at": self.clock()})
        self.store.save(new, state.revision)
        return new

    def _authorize_base(self, provider: ChatProvider, state: SetupState) -> str:
        key = setup_key(state)
        if base := self.store.authorize_link(key):
            return base
        base = provider.begin_install(state, self.store.config_item(key)).authorize_link
        self.store.set_authorize_link(key, base)
        return base

    def _drive(self, provider: ChatProvider, state: SetupState) -> SetupState:
        key = setup_key(state)
        if needs_app_creation(state):
            try:
                created = provider.begin_install(state, self.store.config_item(key))
            except Exception as exc:  # health: allow BLE001 -- provider and adapter errors carry provider text, so only the exception type is logged
                logger.warning("chat install app creation failed provider=%s error=%s", state.provider_id, type(exc).__name__)
                return self._fail(provider, state, SetupErrorCode.app_create_failed)
            self.store.set_authorize_link(key, created.authorize_link)
            state = self._apply(provider, state, SetupEvent(
                kind=SetupEventKind.app_created, app_id=created.app_id,
                authorize_link=self._with_nonce(created.authorize_link, key)))
        if state.step is SetupStep.needs_allow and (state.next_action.link is None or state.next_action.kind is not NextActionKind.open_link):
            try:
                state = self._attach_link(state, self._with_nonce(self._authorize_base(provider, state), key))
            except StaleRevision:
                raise
            except Exception as exc:  # health: allow BLE001 -- provider and adapter errors carry provider text, so only the exception type is logged
                logger.warning("chat install link failed provider=%s error=%s", state.provider_id, type(exc).__name__)
                return self._fail(provider, state, SetupErrorCode.app_create_failed)
        if state.step is SetupStep.installing:
            state = self._finish(provider, state)
        return state

    def status(self, bot: str, provider_id: str, workspace: str) -> tuple[SetupState, Installation | None]:
        self._provider(provider_id)
        state = self._current(bot, provider_id, workspace)
        return state, self._installation_of(state)

    def _installation_of(self, state: SetupState) -> Installation | None:
        if state.installation_id is None or state.step is not SetupStep.ready:
            return None
        return self.store.installation(state.installation_id)

    def begin(self, bot: str, provider_id: str, workspace: str) -> tuple[SetupState, Installation | None]:
        provider = self._provider(provider_id)
        state = self._current(bot, provider_id, workspace)
        if state.step is SetupStep.ready:
            return state, self._installation_of(state)
        if not (self.public_url() or "").startswith("https://"):
            raise ChatServiceError(ChatRpcErrorReason.needs_public_url, state, SET_PUBLIC_URL_ACTION)
        try:
            state = self._apply(provider, state, SetupEvent(kind=SetupEventKind.begin))
            if state.step is SetupStep.needs_allow and state.next_action.link:
                state = self._attach_link(state, self._with_nonce(self._authorize_base(provider, state), setup_key(state)))
            else:
                state = self._drive(provider, state)
        except StaleRevision:
            raise ChatServiceError(ChatRpcErrorReason.stale_revision, self._current(bot, provider_id, workspace)) from None
        return state, self._installation_of(state)

    def advance(self, bot: str, provider_id: str, workspace: str, event: SetupEventKind, expected_revision: int,
                manual_step=None, vault_item_id: str | None = None) -> tuple[SetupState, Installation | None]:
        provider = self._provider(provider_id)
        state = self._current(bot, provider_id, workspace)
        if state.revision != expected_revision:
            raise ChatServiceError(ChatRpcErrorReason.stale_revision, state)
        if event is SetupEventKind.begin:
            return self.begin(bot, provider_id, workspace)
        if event is SetupEventKind.revoked:
            return self.revoke(bot, provider_id, workspace)
        if event not in CLIENT_EVENTS:
            raise ChatServiceError(ChatRpcErrorReason.invalid_event, state)
        try:
            if event is SetupEventKind.allow_granted:
                new = self._adopt(provider, state, vault_item_id)
            else:
                new = self._client_event(provider, state, event, manual_step, vault_item_id)
        except StaleRevision:
            raise ChatServiceError(ChatRpcErrorReason.stale_revision, self._current(bot, provider_id, workspace)) from None
        if new is state:
            raise ChatServiceError(ChatRpcErrorReason.invalid_event, state)
        return new, self._installation_of(new)

    def _client_event(self, provider, state, event, manual_step, vault_item_id) -> SetupState:
        if event is SetupEventKind.manual_step_done and manual_step is None and state.step is SetupStep.needs_manual_step:
            from tui_gateway.contracts.chat_provider import ProviderCapability
            manual_step = ProviderCapability(state.next_action.action_id)
        new = self._apply(provider, state, SetupEvent(kind=event, manual_step=manual_step))
        if new is state:
            return state
        if event is SetupEventKind.credential_saved and vault_item_id:
            self.store.set_config_item(setup_key(new), vault_item_id)
        return self._drive(provider, new)

    def _adopt(self, provider: ChatProvider, state: SetupState, vault_item_id: str | None) -> SetupState:
        if state.step is not SetupStep.needs_allow or not vault_item_id:
            return state
        try:
            installation = provider.adopt_token(state, vault_item_id)
        except Exception as exc:  # health: allow BLE001 -- provider and adapter errors carry provider text, so only the exception type is logged
            logger.warning("chat install adopt failed provider=%s error=%s", state.provider_id, type(exc).__name__)
            return self._fail(provider, state, SetupErrorCode.install_failed)
        return self._complete(provider, state, installation)

    def _complete(self, provider: ChatProvider, state: SetupState, installation: Installation) -> SetupState:
        if not installation.owner_user_id:
            return self._fail(provider, state, SetupErrorCode.install_failed)
        try:
            env_keys = [*provider.adapter_env(installation), *([provider.allowed_users_env] if provider.allowed_users_env else [])]
            self.store.save_installation(installation, env_keys)
        except StaleRevision:
            raise
        except Exception as exc:  # health: allow BLE001 -- provider and adapter errors carry provider text, so only the exception type is logged
            logger.warning("chat install persist failed provider=%s error=%s", state.provider_id, type(exc).__name__)
            return self._fail(provider, state, SetupErrorCode.install_failed)
        state = self._apply(provider, state, SetupEvent(kind=SetupEventKind.allow_granted, installation_id=installation.id))
        return self._finish(provider, state)

    def _finish(self, provider: ChatProvider, state: SetupState) -> SetupState:
        installation = self.store.installation(state.installation_id) if state.installation_id else None
        if installation is None or not installation.owner_user_id:
            return self._fail(provider, state, SetupErrorCode.install_failed)
        try:
            env = dict(provider.adapter_env(installation))
            if provider.allowed_users_env:
                env[provider.allowed_users_env] = installation.owner_user_id
            self.control.apply_env(state.bot, provider.provider_id, env, [])
            self.control.reload(state.bot)
        except Exception as exc:  # health: allow BLE001 -- provider and adapter errors carry provider text, so only the exception type is logged
            logger.warning("chat install adapter start failed provider=%s error=%s", state.provider_id, type(exc).__name__)
            return self._fail(provider, state, SetupErrorCode.install_failed)
        return self._apply(provider, state, SetupEvent(kind=SetupEventKind.installed))

    def complete_redirect(self, raw_state: str, code: str | None, error: str | None) -> RedirectOutcome:
        key = self.store.consume_nonce(raw_state) if raw_state else None
        if key is None:
            return RedirectOutcome.rejected
        try:
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
            try:
                installation = provider.complete_install(state, code)
            except Exception as exc:  # health: allow BLE001 -- provider and adapter errors carry provider text, so only the exception type is logged
                logger.warning("chat install redirect failed provider=%s error=%s", key[1], type(exc).__name__)
                self._fail(provider, state, SetupErrorCode.install_failed)
                return RedirectOutcome.completed
            self._complete(provider, state, installation)
            return RedirectOutcome.completed
        except (StaleRevision, ChatServiceError):
            return RedirectOutcome.rejected

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
            raise ChatServiceError(ChatRpcErrorReason.provider_failed, state) from None

    def spaces(self, bot: str, provider_id: str, workspace: str) -> list[SpaceRef]:
        provider, state, installation = self._installed(bot, provider_id, workspace)
        return self._call(state, lambda: provider.list_spaces(installation))

    def join(self, bot: str, provider_id: str, workspace: str, space_id: str, hello: bool) -> SpaceJoin:
        provider, state, installation = self._installed(bot, provider_id, workspace)
        result = self._call(state, lambda: provider.join_space(installation, space_id))
        from tui_gateway.contracts.chat_provider import SpaceJoinOutcome
        self.store.set_binding(installation.id, space_id, bot, result.outcome is not SpaceJoinOutcome.needs_invite, hello)
        return result

    def bindings(self, bot: str) -> list[Binding]:
        return [row.wire() for row in self.store.bindings(bot)]

    def revoke(self, bot: str, provider_id: str, workspace: str) -> tuple[SetupState, Installation | None]:
        provider = self._provider(provider_id)
        state = self._current(bot, provider_id, workspace)
        installation = self.store.installation(state.installation_id) if state.installation_id else None
        if installation is not None:
            self._call(state, lambda: provider.revoke(installation))
            keys = self.store.env_keys(installation.id)
            try:
                self.control.apply_env(bot, provider_id, {}, keys)
                self.control.reload(bot)
            except Exception as exc:  # health: allow BLE001 -- provider and adapter errors carry provider text, so only the exception type is logged
                logger.warning("chat install adapter stop failed provider=%s error=%s", provider_id, type(exc).__name__)
                raise ChatServiceError(ChatRpcErrorReason.provider_failed, state) from None
            self.store.delete_bindings(installation.id)
            self.store.mark_revoked(installation.id, self.clock())
        try:
            state = self._apply(provider, state, SetupEvent(kind=SetupEventKind.revoked))
        except StaleRevision:
            raise ChatServiceError(ChatRpcErrorReason.stale_revision, self._current(bot, provider_id, workspace)) from None
        return state, None


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


def pending_welcome(store: ChatInstallStore, bot: str, provider_id: str, workspace_id: str) -> Installation | None:
    installation = store.installation_for_workspace(provider_id, workspace_id, bot)
    if installation is None or not installation.owner_user_id or not store.claim_welcome(installation.id):
        return None
    return installation
