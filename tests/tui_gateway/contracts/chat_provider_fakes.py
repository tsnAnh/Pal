from __future__ import annotations

from tui_gateway.chat_install import (
    AppCreated,
    BotIdentitySource,
    ChatProvider,
    IdentityUpdate,
    SetupKey,
    SpaceJoin,
    StaleRevision,
    setup_key,
)
from tui_gateway.contracts.chat_provider import (
    Capabilities,
    CapabilityEntry,
    CapabilityMode,
    IdentityPolicy,
    IdentityProjection,
    IdentityUpdateOutcome,
    Installation,
    InstallationStatus,
    NextAction,
    NextActionKind,
    ProviderCapability,
    SetupState,
    SpaceJoinOutcome,
    SpaceKind,
    SpaceRef,
)

FAKE_TOKEN = "fake-token-do-not-use"
FIXED_NOW = 1_700_000_000.0


class MemorySetupStore:
    def __init__(self) -> None:
        self._states: dict[SetupKey, SetupState] = {}

    def load(self, key: SetupKey) -> SetupState | None:
        return self._states.get(key)

    def save(self, state: SetupState, expected_revision: int) -> None:
        current = self._states.get(setup_key(state))
        if (current.revision if current else 0) != expected_revision:
            raise StaleRevision(setup_key(state))
        self._states[setup_key(state)] = state


class _FakeBase(ChatProvider):
    caps: Capabilities
    allowed_users_env = "FAKE_ALLOWED_USERS"

    def __init__(self) -> None:
        self.apps_created: list[str] = []
        self.installs: dict[str, Installation] = {}
        self.joined: set[str] = set()
        self.config_credentials: list[tuple[str, str | None]] = []
        self.reject_config_credential = False

    def accept_config_credential(self, state: SetupState, vault_item_id: str, refresh_vault_item_id: str | None) -> None:
        if self.reject_config_credential:
            raise ValueError("provider secret text")
        self.config_credentials.append((vault_item_id, refresh_vault_item_id))

    def capabilities(self, workspace: str | None = None) -> Capabilities:
        return self.caps

    def begin_install(self, state: SetupState, config_vault_item_id: str | None) -> AppCreated:
        app_id = f"{self.provider_id}-app-{len(self.apps_created) + 1}"
        self.apps_created.append(app_id)
        return AppCreated(app_id=app_id, authorize_link=f"https://{self.provider_id}.invalid/allow/{app_id}")

    def _install(self, state: SetupState) -> Installation:
        install_id = f"{self.provider_id}-install-{state.bot}-{state.workspace}"
        self.installs.setdefault(install_id, Installation(
            id=install_id, provider_id=self.provider_id, bot=state.bot, workspace_id=state.workspace,
            workspace_name=f"Workspace {state.workspace}", status=InstallationStatus.active,
            created_at=FIXED_NOW, updated_at=FIXED_NOW, vault_item_ids=[f"vault-{install_id}-bot"],
        ))
        return self.installs[install_id]

    def complete_install(self, state: SetupState, authorization_code: str) -> Installation:
        return self._install(state)

    def adopt_token(self, state: SetupState, vault_item_id: str) -> Installation:
        return self._install(state)

    def authorizing_identity(self, installation: Installation) -> str | None:
        return "U_OWNER"

    def adapter_env(self, installation: Installation) -> dict[str, str]:
        return {"FAKE_BOT_TOKEN": FAKE_TOKEN}

    def identity_projection(self, source: BotIdentitySource) -> IdentityProjection:
        policy = self.caps.identity_policy
        return IdentityProjection(
            app_name=source.display_name[: policy.app_name_max],
            display_name=source.display_name[: policy.display_name_max],
            username=source.display_name.lower().replace(" ", "-")[: policy.username_max],
            avatar_ref=source.avatar_path,
        )

    def list_spaces(self, installation: Installation) -> list[SpaceRef]:
        return [
            SpaceRef(id="s-public", name="general", kind=SpaceKind.public, joined="s-public" in self.joined),
            SpaceRef(id="s-private", name="secret-plans", kind=SpaceKind.private, joined=False),
        ]

    def join_space(self, installation: Installation, space_id: str) -> SpaceJoin:
        if space_id == "s-private":
            return SpaceJoin(SpaceJoinOutcome.needs_invite,
                             NextAction(kind=NextActionKind.copy_text, action_id="invite", copy_text="/invite @pal"))
        outcome = SpaceJoinOutcome.already_joined if space_id in self.joined else SpaceJoinOutcome.joined
        self.joined.add(space_id)
        return SpaceJoin(outcome, NextAction(kind=NextActionKind.none, action_id="none"))

    def revoke(self, installation: Installation) -> None:
        self.installs.pop(installation.id, None)


class CredentialAppFake(_FakeBase):
    provider_id = "fake-credential"
    caps = Capabilities(
        provider_id="fake-credential", requires_config_credential=True, creates_app=True,
        capabilities=[
            CapabilityEntry(capability=ProviderCapability.set_icon, mode=CapabilityMode.guided),
            CapabilityEntry(capability=ProviderCapability.app_level_credential, mode=CapabilityMode.automatic),
            CapabilityEntry(capability=ProviderCapability.gateway_redirect, mode=CapabilityMode.automatic),
            CapabilityEntry(capability=ProviderCapability.join_private_space, mode=CapabilityMode.guided),
        ],
        identity_policy=IdentityPolicy(app_name_max=35, display_name_max=80, username_max=21,
                                       avatar_max_bytes=1_000_000, avatar_min_px=512),
    )


class AuthorizeOnlyFake(_FakeBase):
    provider_id = "fake-authorize"
    caps = Capabilities(
        provider_id="fake-authorize", requires_config_credential=False, creates_app=False,
        capabilities=[
            CapabilityEntry(capability=ProviderCapability.set_icon, mode=CapabilityMode.unsupported),
            CapabilityEntry(capability=ProviderCapability.join_public_space, mode=CapabilityMode.automatic),
        ],
        identity_policy=IdentityPolicy(app_name_max=32, display_name_max=32, username_max=32,
                                       avatar_max_bytes=256_000, avatar_min_px=128),
    )
