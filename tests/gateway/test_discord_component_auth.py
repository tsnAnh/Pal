"""Security regression tests: Discord component views honor allowlists.

The interactive component views (SlashConfirmView,
UpdatePromptView, ModelPickerView, ClarifyChoiceView) historically accepted only
``allowed_user_ids``. Deployments that configure DISCORD_ALLOWED_ROLES
without DISCORD_ALLOWED_USERS therefore had a wide-open component
surface: any guild member who could see the prompt could answer
commands, cancel slash confirmations, or switch the model -- even when
the same user would be rejected at the slash and on_message gates.

These tests pin user/role/global allowlist semantics, explicit allow-all
handling, and fail-closed behavior so the parity cannot regress.
"""

from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest

from gateway.config import PlatformConfig

# Trigger the shared discord mock from tests/gateway/conftest.py before
# importing the production module.
from plugins.platforms.discord.adapter import (
    ClarifyChoiceView,
    DiscordAdapter,
    ModelPickerView,
    SlashConfirmView,
    UpdatePromptView,
)
from plugins.platforms.discord.adapter_component_auth import _component_check_auth


@pytest.fixture(autouse=True)
def _clear_component_auth_env(monkeypatch):
    from unittest.mock import MagicMock, patch

    for name in (
        "DISCORD_ALLOW_ALL_USERS",
        "GATEWAY_ALLOW_ALL_USERS",
        "GATEWAY_ALLOWED_USERS",
    ):
        monkeypatch.delenv(name, raising=False)

    # Default-mock PairingStore so tests don't hit the filesystem.
    # Pairing-specific tests override this with explicit mock values.
    mock_store = MagicMock()
    mock_store.is_approved.return_value = False
    with patch("gateway.pairing.PairingStore", return_value=mock_store):
        yield


# ---------------------------------------------------------------------------
# Direct helper coverage -- the views all delegate to this helper, so
# pinning the helper's contract pins all call sites.
# ---------------------------------------------------------------------------


def _interaction(user_id, role_ids=None, *, drop_user=False, drop_roles=False):
    """Build a mock interaction with the requested user/role shape.

    drop_user simulates a payload whose .user attribute is None.
    drop_roles simulates a payload where .user has no .roles attribute
    at all (DM-context Member, raw User payload).
    """
    if drop_user:
        return SimpleNamespace(user=None)

    user_kwargs = {"id": user_id}
    if not drop_roles:
        user_kwargs["roles"] = [SimpleNamespace(id=r) for r in (role_ids or [])]
    return SimpleNamespace(user=SimpleNamespace(**user_kwargs))


# ── no policy configured -> deny unless allow-all is explicit ──────────────


@pytest.mark.parametrize(
    ("env_name", "env_value"),
    [
        ("DISCORD_ALLOW_ALL_USERS", "true"),
        ("GATEWAY_ALLOW_ALL_USERS", "yes"),
    ],
)
def test_component_check_explicit_allow_all_passes(monkeypatch, env_name, env_value):
    monkeypatch.setenv(env_name, env_value)
    interaction = _interaction(11111)
    assert _component_check_auth(interaction, set(), set()) is True


# ── user allowlist ─────────────────────────────────────────────────────────


@pytest.mark.parametrize("snapshot", [{"11111"}, {"*"}])
@pytest.mark.parametrize(("verdict", "expected"), [(None, True), (True, True), (False, False)])
def test_snapshot_user_is_confirmed_with_the_live_check(snapshot, verdict, expected):
    # The user set is the adapter's connect-time snapshot; None means no live check is wired.
    seen = []

    def live_auth(interaction):
        seen.append(interaction.user.id)
        return verdict

    assert _component_check_auth(_interaction(11111), snapshot, set(), live_auth=live_auth) is expected
    assert seen == [11111]


@pytest.mark.asyncio
async def test_prompt_buttons_follow_a_revoke_made_after_connect():
    # `hermes pairing revoke` in another process rewrites .env and the pairing store, never the
    # adapter's snapshot; a prompt's buttons must follow the gateway's per-call check instead.
    adapter = DiscordAdapter(PlatformConfig(enabled=True, token="***"))
    adapter._allowed_user_ids = {"11111"}
    live = {"11111": True}
    adapter.set_authorization_check(lambda user_id, chat_type=None, chat_id=None, **_: live.get(user_id, False))
    channel = SimpleNamespace(send=AsyncMock(return_value=SimpleNamespace(id=1)))
    adapter._client = SimpleNamespace(get_channel=lambda _chat_id: channel, fetch_channel=AsyncMock())

    result = await adapter.send_slash_confirm(
        chat_id="555", title="Reload", message="Reload MCP servers?", session_key="discord:555", confirm_id="c1")
    assert result.success is True
    view = channel.send.call_args.kwargs["view"]
    assert view._check_auth(_interaction(11111)) is True
    live["11111"] = False
    assert view._check_auth(_interaction(11111)) is False


# ── role allowlist OR semantics ────────────────────────────────────────────


# ── fail-closed on missing role data ───────────────────────────────────────


# ---------------------------------------------------------------------------
# View construction: every view must accept allowed_role_ids and route
# through the shared helper. Default value preserves prior call-sites.
# ---------------------------------------------------------------------------


def test_slash_confirm_view_accepts_role_allowlist():
    view = SlashConfirmView(
        session_key="sess-1",
        confirm_id="c1",
        allowed_user_ids=set(),
        allowed_role_ids={42},
    )
    assert view._check_auth(_interaction(99999, role_ids=[42])) is True
    assert view._check_auth(_interaction(99999, role_ids=[7])) is False


def test_update_prompt_view_accepts_role_allowlist():
    view = UpdatePromptView(
        session_key="sess-1",
        allowed_user_ids=set(),
        allowed_role_ids={42},
    )
    assert view._check_auth(_interaction(99999, role_ids=[42])) is True
    assert view._check_auth(_interaction(99999, role_ids=[7])) is False


def test_clarify_choice_view_accepts_role_allowlist():
    view = ClarifyChoiceView(
        choices=["one", "two"],
        clarify_id="clarify-1",
        allowed_user_ids=set(),
        allowed_role_ids={42},
    )
    assert view._check_auth(_interaction(99999, role_ids=[42])) is True
    assert view._check_auth(_interaction(99999, role_ids=[7])) is False


# ---------------------------------------------------------------------------
# Empty allowlists across views: fail closed unless allow-all is explicit.
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "view_factory",
    [
        lambda: SlashConfirmView(session_key="s", confirm_id="c", allowed_user_ids=set()),
        lambda: UpdatePromptView(session_key="s", allowed_user_ids=set()),
        lambda: ClarifyChoiceView(
            choices=["one"],
            clarify_id="c",
            allowed_user_ids=set(),
        ),
    ],
)
def test_views_empty_allowlists_reject_by_default(view_factory, monkeypatch):
    monkeypatch.delenv("DISCORD_ALLOW_ALL_USERS", raising=False)
    monkeypatch.delenv("GATEWAY_ALLOW_ALL_USERS", raising=False)
    monkeypatch.delenv("GATEWAY_ALLOWED_USERS", raising=False)
    view = view_factory()
    assert view._check_auth(_interaction(99999)) is False


def test_model_picker_view_empty_allowlists_reject_by_default(monkeypatch):
    monkeypatch.delenv("DISCORD_ALLOW_ALL_USERS", raising=False)
    monkeypatch.delenv("GATEWAY_ALLOW_ALL_USERS", raising=False)
    monkeypatch.delenv("GATEWAY_ALLOWED_USERS", raising=False)

    async def _noop(*_a, **_k):
        return ""

    view = ModelPickerView(
        providers=[],
        current_model="m",
        current_provider="p",
        session_key="s",
        on_model_selected=_noop,
        allowed_user_ids=set(),
    )
    assert view.allowed_role_ids == set()
    assert view._check_auth(_interaction(99999)) is False

    # Cancel is gated too: a stranger cannot close the owner's picker.
    import asyncio
    from unittest.mock import AsyncMock

    stranger = _interaction(99999)
    stranger.response = SimpleNamespace(send_message=AsyncMock())
    asyncio.run(view._on_cancel(stranger))
    assert view.resolved is False
    stranger.response.send_message.assert_awaited_once()
    assert stranger.response.send_message.await_args.kwargs.get("ephemeral") is True


def test_view_empty_allowlists_allow_with_explicit_allow_all(monkeypatch):
    monkeypatch.setenv("DISCORD_ALLOW_ALL_USERS", "true")
    view = SlashConfirmView(session_key="s", confirm_id="c", allowed_user_ids=set())
    assert view._check_auth(_interaction(99999)) is True


# ---------------------------------------------------------------------------
# Pairing store: users approved via ``hermes pairing approve`` must be
# authorized even without DISCORD_ALLOWED_USERS / DISCORD_ALLOWED_ROLES.
# ---------------------------------------------------------------------------


def test_component_check_pairing_approved_user_passes(monkeypatch):
    """User approved in pairing store passes even without allowlists."""
    from unittest.mock import MagicMock, patch

    mock_store = MagicMock()
    mock_store.is_approved.return_value = True
    # Override the autouse fixture's mock with approved=True
    with patch("gateway.pairing.PairingStore", return_value=mock_store):
        interaction = _interaction(11111)
        assert _component_check_auth(interaction, set(), set()) is True
    mock_store.is_approved.assert_called_once_with("discord", "11111")


def test_views_stay_user_scope():
    sc = SlashConfirmView(
        session_key="s", confirm_id="c", allowed_user_ids={"11111"}
    )
    assert sc._check_auth(_interaction(11111)) is True

