from __future__ import annotations

import io
import json
import logging
import threading

import pytest
from PIL import Image

from agent.vault_store import VaultError, VaultStore
from gateway.chat_slack.api import ERROR_CODES, SlackApi, SlackSetupError
from gateway.chat_slack.avatar import prepare_avatar
from gateway.chat_slack.provider import PROBE_APP_NAME, SlackProvider
from gateway.chat_slack.records import SlackRecords
from gateway.chat_slack.token_store import ROTATE_MARGIN_S
from tests.gateway.chat_slack.fake_slack import BOT_TOKEN, REFRESH, FakeSlack
from tests.tui_gateway.contracts.chat_provider_fakes import FAKE_TOKEN, FIXED_NOW, MemorySetupStore
from tests.tui_gateway.contracts.test_chat_provider_contract import SCRIPT, Gateway, _fixture_models
from tui_gateway import chat_install as ci
from tui_gateway.chat_providers import provider_for
from tui_gateway.contracts import chat_provider as wire

REDIRECT = "https://gateway.invalid/chat/slack/redirect"
LONG = "Pal the Extremely Helpful and Very Thorough Research Assistant Who Never Sleeps At All, Ever!"
CAP = wire.ProviderCapability


class Kit:
    def __init__(self, tmp_path, slack: FakeSlack | None = None, name: str = "Pal Helper"):
        self.slack = slack or FakeSlack(now=FIXED_NOW)
        self.vault = VaultStore(tmp_path / "vault")
        self.config_item = self.vault.add_item("api_key", "Slack configuration token", {"api_key": REFRESH}).id
        self.sleeps: list[float] = []
        avatar = tmp_path / "avatar.png"
        Image.new("RGBA", (800, 600), (10, 200, 30, 0)).save(avatar)
        self.provider = SlackProvider(
            redirect_url=REDIRECT, vault=self.vault, api=SlackApi(self.slack.transport, sleep=self.sleeps.append),
            records=SlackRecords(tmp_path / "records.json"), clock=lambda: self.slack.now,
            identity=lambda bot: ci.BotIdentitySource(bot, name, str(avatar)))

    def state(self, app_id=None):
        return ci.initial_state("pal", "slack", "w1", FIXED_NOW).model_copy(update={"app_id": app_id})

    def begin(self, app_id=None):
        return self.provider.begin_install(self.state(app_id), self.config_item)

    def install(self):
        created = self.begin()
        return created, self.provider.complete_install(self.state(created.app_id), "code-1")

    def secrets(self):
        return [json.dumps(self.vault.resolve_secret(m.id)) for m in self.vault.list_items()]


def _modes(caps):
    return {e.capability: e.mode for e in caps.capabilities}


def test_manifest_create_has_identity_scopes_socket_mode_and_redirect(tmp_path):
    kit = Kit(tmp_path)
    kit.provider.records.update_workspace("w1", capabilities={"gateway_redirect": "automatic"})
    created = kit.begin()
    manifest = kit.slack.apps[created.app_id]
    from urllib.parse import parse_qs, urlsplit
    link = urlsplit(created.authorize_link)
    assert link._replace(query="").geturl() == "https://slack.invalid/oauth"
    assert parse_qs(link.query) == {"app": [created.app_id], "redirect_uri": [REDIRECT]}
    assert manifest["display_information"]["name"] == "Pal Helper"
    assert manifest["features"]["bot_user"]["display_name"] == "Pal Helper"
    assert manifest["oauth_config"]["redirect_urls"] == [REDIRECT]
    assert manifest["settings"]["socket_mode_enabled"] is True
    required = {"channels:join", "channels:read", "channels:history", "groups:read", "groups:history", "im:history",
                "im:write", "app_mentions:read", "chat:write", "reactions:read", "reactions:write", "files:read",
                "files:write"}
    assert required <= set(manifest["oauth_config"]["scopes"]["bot"])


def test_identity_limits(tmp_path):
    kit = Kit(tmp_path, name=LONG)
    projection = kit.provider.identity_projection(ci.BotIdentitySource("pal", LONG, None))
    assert projection.app_name == LONG[:35].strip() and len(projection.app_name) <= 35
    assert projection.display_name == LONG[:80].strip()
    assert len(projection.username) <= 21 and projection.username == "pal-the-extremely-hel"
    created = kit.begin()
    manifest = kit.slack.apps[created.app_id]
    assert len(manifest["display_information"]["name"]) <= 35
    assert len(manifest["features"]["bot_user"]["display_name"]) <= 80


def test_begin_install_is_idempotent(tmp_path):
    kit = Kit(tmp_path)
    first = kit.begin()
    again = kit.begin(first.app_id)
    restarted = kit.begin()
    assert first == again == restarted and kit.slack.created == 1
    assert kit.slack.calls.count("apps.manifest.update") == 2
    assert kit.slack.calls.count("apps.manifest.create") == 1


def test_code_exchange_stores_bot_token_only_in_vault(tmp_path):
    kit = Kit(tmp_path)
    _, installation = kit.install()
    payload = installation.model_dump_json()
    assert BOT_TOKEN not in payload and FAKE_TOKEN not in payload
    bot_item = installation.vault_item_ids[0]
    assert kit.vault.resolve_secret(bot_item) == {"api_key": BOT_TOKEN}
    assert FAKE_TOKEN not in (tmp_path / "records.json").read_text()
    assert kit.provider.authorizing_user(installation) == "UOWNER"
    assert installation.workspace_id == "T1"


def test_join_public_and_private(tmp_path):
    kit = Kit(tmp_path)
    _, installation = kit.install()
    spaces = {s.id: s for s in kit.provider.list_spaces(installation)}
    assert spaces["C1"].kind is wire.SpaceKind.public and spaces["G1"].kind is wire.SpaceKind.private
    assert kit.provider.join_space(installation, "C1").outcome is wire.SpaceJoinOutcome.joined
    assert kit.provider.join_space(installation, "C1").outcome is wire.SpaceJoinOutcome.already_joined
    private = kit.provider.join_space(installation, "G1")
    assert private.outcome is wire.SpaceJoinOutcome.needs_invite
    assert private.next_action.copy_text == "/invite @Pal Helper"
    assert private.next_action.link == "https://slack.com/app_redirect?team=T1&channel=G1"


def test_rotation_only_near_expiry(tmp_path):
    kit = Kit(tmp_path)
    tokens = kit.provider.tokens
    tokens.bind("w1", kit.config_item)
    first = tokens.valid_config_token("w1")
    assert kit.slack.rotations == 1 and tokens.valid_config_token("w1") == first
    kit.slack.now += 43200 - ROTATE_MARGIN_S + 1
    assert tokens.valid_config_token("w1") != first and kit.slack.rotations == 2
    stored = json.loads(kit.vault.resolve_secret(kit.config_item)["api_key"])
    assert stored["refresh_token"] in kit.slack.refresh


def test_concurrent_calls_rotate_once(tmp_path):
    kit = Kit(tmp_path)
    kit.provider.tokens.bind("w1", kit.config_item)
    kit.slack.rotate_gate = threading.Event()
    results = []
    threads = [threading.Thread(target=lambda: results.append(kit.provider.tokens.valid_config_token("w1")))
               for _ in range(2)]
    for t in threads:
        t.start()
    kit.slack.rotate_gate.set()
    for t in threads:
        t.join(10)
    assert kit.slack.rotations == 1 and len(set(results)) == 1 and len(results) == 2


def test_write_failure_is_retried_from_memory(tmp_path, monkeypatch):
    kit = Kit(tmp_path)
    kit.provider.tokens.bind("w1", kit.config_item)
    real, failures = kit.vault.update_item, {"left": 4}

    def flaky(*args, **kwargs):
        if failures["left"]:
            failures["left"] -= 1
            raise VaultError("disk full")
        return real(*args, **kwargs)

    monkeypatch.setattr(kit.vault, "update_item", flaky)
    with pytest.raises(SlackSetupError):
        kit.provider.tokens.valid_config_token("w1")
    token = kit.provider.tokens.valid_config_token("w1")
    assert kit.slack.rotations == 1 and token in kit.slack.access
    stored = json.loads(kit.vault.resolve_secret(kit.config_item)["api_key"])
    assert stored["refresh_token"] in kit.slack.refresh


def test_rejected_refresh_token_asks_for_new_credential(tmp_path):
    kit = Kit(tmp_path)
    kit.provider.tokens.bind("w1", kit.config_item)
    kit.slack.refresh = set()
    with pytest.raises(SlackSetupError) as info:
        kit.provider.tokens.valid_config_token("w1")
    assert info.value.code is wire.SetupErrorCode.credential_expired
    assert info.value.fix is wire.FixAction.reenter_credential


@pytest.mark.parametrize("slack_error", sorted(ERROR_CODES))
def test_every_slack_error_maps_to_a_code_with_a_fix(tmp_path, slack_error):
    kit = Kit(tmp_path)
    kit.slack.fail["apps.manifest.create"] = "network" if slack_error == "network_failure" else slack_error
    with pytest.raises(SlackSetupError) as info:
        kit.begin()
    assert info.value.code is ERROR_CODES[slack_error]
    assert info.value.fix is ci.FIX_FOR_ERROR[info.value.code]
    assert slack_error not in str(info.value)


def test_rate_limit_honours_retry_after(tmp_path):
    kit = Kit(tmp_path)
    kit.slack.rate_limit["apps.manifest.create"] = 1
    kit.begin()
    assert kit.sleeps == [3.0]
    kit.slack.rate_limit["apps.manifest.update"] = 5
    with pytest.raises(SlackSetupError) as info:
        kit.begin()
    assert info.value.code is wire.SetupErrorCode.provider_unreachable and info.value.retry_after == 3.0


def test_probe_success_leaves_no_app_and_flips_capabilities(tmp_path):
    kit = Kit(tmp_path)
    checks = kit.provider.probe_workspace("w1", kit.config_item)
    assert all(c.passed for c in checks) and {c.capability for c in checks} == {
        CAP.set_icon, CAP.app_level_credential, CAP.gateway_redirect, CAP.unattended_refresh}
    assert kit.slack.created == 1 and kit.slack.apps == {}
    modes = _modes(kit.provider.capabilities("w1"))
    assert all(modes[c] is wire.CapabilityMode.automatic for c in
               (CAP.set_icon, CAP.app_level_credential, CAP.gateway_redirect, CAP.unattended_refresh))
    assert _modes(kit.provider.capabilities()) == _modes(ci.SLACK_CAPABILITIES)
    assert kit.provider.records.workspace("w1")["refresh_token_lifetime"] == "unknown"


def test_probe_guided_outcomes(tmp_path):
    kit = Kit(tmp_path, FakeSlack(icon_ok=False, app_token_ok=False, redirect_ok=False, now=FIXED_NOW))
    checks = {c.capability: c for c in kit.provider.probe_workspace("w1", kit.config_item)}
    assert checks[CAP.gateway_redirect].slack_error == "invalid_redirect_urls"
    assert checks[CAP.set_icon].slack_error == "unknown_method"
    assert kit.slack.apps == {}
    modes = _modes(kit.provider.capabilities("w1"))
    assert [modes[c] for c in (CAP.set_icon, CAP.app_level_credential, CAP.gateway_redirect)] == [wire.CapabilityMode.guided] * 3
    mark = len(kit.slack.calls)
    created = kit.begin()
    assert "redirect_urls" not in kit.slack.apps[created.app_id]["oauth_config"]
    assert not {"apps.icon.set", "apps.token.create"} & set(kit.slack.calls[mark:])


def test_probe_mid_failure_still_deletes_app(tmp_path):
    kit = Kit(tmp_path)
    kit.slack.fail["apps.token.create"] = "network"
    with pytest.raises(SlackSetupError) as info:
        kit.provider.probe_workspace("w1", kit.config_item)
    assert info.value.code is wire.SetupErrorCode.provider_unreachable
    assert kit.slack.created == 1 and kit.slack.apps == {}
    assert "capabilities" not in kit.provider.records.workspace("w1")


def test_probe_delete_failure_names_app(tmp_path):
    kit = Kit(tmp_path)
    kit.slack.fail["apps.manifest.delete"] = "internal_error"
    with pytest.raises(SlackSetupError) as info:
        kit.provider.probe_workspace("w1", kit.config_item)
    assert info.value.app_id == "A1" and "A1" in str(info.value)
    assert kit.slack.apps["A1"]["display_information"]["name"] == PROBE_APP_NAME


def test_revoke_deletes_app_and_vault_items(tmp_path):
    kit = Kit(tmp_path)
    _, installation = kit.install()
    kit.provider.revoke(installation)
    assert kit.slack.apps == {} and "auth.revoke" in kit.slack.calls
    assert {m.id for m in kit.vault.list_items()} == {kit.config_item}


def test_avatar_policy():
    out = prepare_avatar(_png(300, 900))
    with Image.open(io.BytesIO(out)) as image:
        assert image.size == (512, 512) and image.mode == "RGB"
    assert len(out) <= ci.SLACK_IDENTITY_POLICY.avatar_max_bytes


def _png(w, h):
    buf = io.BytesIO()
    Image.new("RGBA", (w, h), (0, 0, 0, 0)).save(buf, format="PNG")
    return buf.getvalue()


def _run_to_ready(gw: Gateway) -> list[wire.SetupStep]:
    steps = []
    for kind in SCRIPT:
        steps.append(gw.send("pal", "w1", kind).step)
    while gw.state("pal", "w1").step is wire.SetupStep.needs_manual_step:
        steps.append(gw.send("pal", "w1", wire.SetupEventKind.manual_step_done).step)
    for kind in (wire.SetupEventKind.allow_granted, wire.SetupEventKind.installed):
        steps.append(gw.send("pal", "w1", kind).step)
    return steps


@pytest.mark.parametrize("automatic", [True, False], ids=["all-automatic", "all-guided"])
def test_contract_script_reaches_ready(tmp_path, caplog, capsys, automatic):
    caplog.set_level(logging.DEBUG)
    kit = Kit(tmp_path, FakeSlack(icon_ok=automatic, app_token_ok=automatic, redirect_ok=automatic, now=FIXED_NOW))
    if automatic:
        kit.provider.probe_workspace("w1", kit.config_item)
    gw = Gateway(kit.provider, MemorySetupStore())
    gw.caps, gw.config_item = kit.provider.capabilities("w1"), kit.config_item
    steps = _run_to_ready(gw)
    assert steps[-1] is wire.SetupStep.ready
    assert (wire.SetupStep.needs_manual_step in steps) is not automatic
    assert kit.slack.created == (2 if automatic else 1)
    assert ("apps.token.create" in kit.slack.calls) is automatic
    payloads = [m.model_dump_json() for m in _fixture_models(_SlackView(gw, kit))]
    assert all(FAKE_TOKEN not in p for p in payloads)
    assert caplog.records and all(FAKE_TOKEN not in r.getMessage() for r in caplog.records)
    out = capsys.readouterr()
    assert FAKE_TOKEN not in out.out + out.err
    assert any(FAKE_TOKEN in s for s in kit.secrets())


class _SlackView:
    def __init__(self, gw, kit):
        self.caps = gw.caps
        state = gw.state("pal", "w1")
        self._state = state
        install = kit.provider._installation("pal", kit.provider.records.app("pal", "w1"))
        self.provider = _Installs(kit.provider, {state.installation_id: install})

    def state(self, bot, workspace):
        return self._state


class _Installs:
    def __init__(self, provider, installs):
        self._p, self.installs = provider, installs

    def __getattr__(self, name):
        return getattr(self._p, name)


def test_registry_returns_slack_provider(tmp_path):
    provider = provider_for("slack", redirect_url=REDIRECT, records=SlackRecords(tmp_path / "r.json"),
                            vault=VaultStore(tmp_path / "v"))
    assert isinstance(provider, SlackProvider) and provider.provider_id == "slack"
    with pytest.raises(ci.ChatProviderError):
        provider_for("nope")


ACCESS = f"xoxe.xoxp-{FAKE_TOKEN}-0"


def _config_items(kit: Kit, access: str = ACCESS, refresh: str | None = REFRESH):
    access_id = kit.vault.add_item("api_key", "access", {"api_key": access}).id
    refresh_id = kit.vault.add_item("api_key", "refresh", {"api_key": refresh}).id if refresh else None
    return access_id, refresh_id


def test_manifest_subscribes_to_membership_and_uninstall_events_and_reads_channels(tmp_path):
    kit = Kit(tmp_path)
    manifest = kit.slack.apps[kit.begin().app_id]
    events = {"member_joined_channel", "member_left_channel", "app_uninstalled", "tokens_revoked"}
    assert events <= set(manifest["settings"]["event_subscriptions"]["bot_events"])
    assert {"channels:read", "groups:read"} <= set(manifest["oauth_config"]["scopes"]["bot"])


def test_both_config_tokens_are_joined_into_one_renewable_pair(tmp_path):
    kit = Kit(tmp_path)
    access_id, refresh_id = _config_items(kit)
    kit.provider.accept_config_credential(kit.state(), access_id, refresh_id)
    assert refresh_id not in {m.id for m in kit.vault.list_items()}
    assert _modes(kit.provider.capabilities("w1"))[CAP.unattended_refresh] is wire.CapabilityMode.automatic
    created = kit.provider.begin_install(kit.state(), access_id)
    assert created.app_id in kit.slack.apps and kit.slack.rotations == 1


def test_access_token_alone_works_but_is_reported_as_not_renewing(tmp_path):
    kit = Kit(tmp_path)
    access_id, _ = _config_items(kit, refresh=None)
    kit.slack.access = {ACCESS}
    kit.provider.accept_config_credential(kit.state(), access_id, None)
    assert _modes(kit.provider.capabilities("w1"))[CAP.unattended_refresh] is wire.CapabilityMode.guided
    assert kit.provider.begin_install(kit.state(), access_id).app_id in kit.slack.apps
    assert kit.slack.rotations == 0
    kit.slack.now += 13 * 3600
    with pytest.raises(SlackSetupError) as info:
        kit.provider.begin_install(kit.state(), access_id)
    assert info.value.code is wire.SetupErrorCode.credential_expired and info.value.fix is wire.FixAction.reenter_credential
    assert kit.slack.rotations == 0


def test_a_refresh_item_that_is_not_a_refresh_token_is_rejected(tmp_path):
    kit = Kit(tmp_path)
    access_id, refresh_id = _config_items(kit, refresh=f"xoxb-{FAKE_TOKEN}")
    with pytest.raises(SlackSetupError) as info:
        kit.provider.accept_config_credential(kit.state(), access_id, refresh_id)
    assert info.value.code is wire.SetupErrorCode.credential_rejected


def _bot_token_item(kit: Kit, token: str = BOT_TOKEN) -> str:
    return kit.vault.add_item("api_key", "bot token", {"api_key": token}).id


def test_adopt_token_validates_with_auth_test_and_leaves_the_owner_unknown(tmp_path, caplog):
    caplog.set_level(logging.DEBUG)
    kit = Kit(tmp_path)
    item_id = _bot_token_item(kit)
    installation = kit.provider.adopt_token(kit.state(), item_id)
    assert kit.slack.calls == ["auth.test"]
    assert (installation.workspace_id, installation.workspace_name, installation.status) == ("T1", "Acme", wire.InstallationStatus.active)
    assert installation.vault_item_ids == [item_id]
    assert kit.provider.authorizing_identity(installation) == ""
    assert BOT_TOKEN not in caplog.text and FAKE_TOKEN not in caplog.text


def test_adopt_token_refuses_a_user_token_and_a_rejected_token(tmp_path):
    kit = Kit(tmp_path)
    with pytest.raises(SlackSetupError) as info:
        kit.provider.adopt_token(kit.state(), _bot_token_item(kit, f"xoxp-{FAKE_TOKEN}"))
    assert info.value.code is wire.SetupErrorCode.credential_rejected and kit.slack.calls == []
    kit.slack.fail["auth.test"] = "invalid_auth"
    with pytest.raises(SlackSetupError) as info:
        kit.provider.adopt_token(kit.state(), _bot_token_item(kit))
    assert info.value.code is wire.SetupErrorCode.credential_rejected


def test_owner_member_ids_are_checked_in_slack_shape(tmp_path):
    parse = Kit(tmp_path).provider.parse_owner_identity
    assert parse(" ufake0000 ") == "UFAKE0000" and parse("WFAKE00000") == "WFAKE00000"
    assert parse("") is None and parse("not a member") is None and parse("C12345678") is None


def _installed(kit: Kit):
    kit.provider.records.update_workspace("w1", capabilities={"set_icon": "automatic"})
    return kit.install()[1]


def test_update_identity_resends_name_and_picture_when_the_icon_is_automatic(tmp_path):
    kit = Kit(tmp_path)
    installation = _installed(kit)
    kit.provider._identity = lambda bot: ci.BotIdentitySource(bot, LONG, None)
    kit.slack.calls.clear()
    update = kit.provider.update_identity(installation)
    manifest = kit.slack.apps[kit.provider.records.app("pal", "w1")["app_id"]]
    assert manifest["display_information"]["name"] == LONG[:35].strip()
    assert manifest["features"]["bot_user"]["display_name"] == LONG[:80].strip()
    assert update.outcome is wire.IdentityUpdateOutcome.updated and update.next_action.kind is wire.NextActionKind.none
    assert kit.slack.calls == ["apps.manifest.update"]
    kit.provider._identity = lambda bot: ci.BotIdentitySource(bot, "Pal", str(tmp_path / "avatar.png"))
    kit.provider.update_identity(installation)
    assert kit.slack.calls[-1] == "apps.icon.set"


def test_an_install_under_the_empty_workspace_key_uses_the_capabilities_its_probe_recorded(tmp_path):
    kit = Kit(tmp_path)
    kit.provider.records.update_workspace("", capabilities={"set_icon": "automatic"})
    kit.provider.begin_install(ci.initial_state("pal", "slack", "", FIXED_NOW), kit.config_item)
    assert "apps.icon.set" in kit.slack.calls
    assert _modes(kit.provider.capabilities(""))[CAP.set_icon] is wire.CapabilityMode.automatic
    assert _modes(kit.provider.capabilities())[CAP.set_icon] is wire.CapabilityMode.guided


def test_update_identity_returns_the_guided_avatar_step_when_the_icon_is_manual(tmp_path):
    kit = Kit(tmp_path)
    installation = kit.install()[1]
    kit.slack.calls.clear()
    update = kit.provider.update_identity(installation)
    assert update.outcome is wire.IdentityUpdateOutcome.needs_manual_avatar
    assert (update.next_action.kind, update.next_action.action_id) == (wire.NextActionKind.button, "set_icon")
    assert "apps.icon.set" not in kit.slack.calls


def test_profile_identity_reads_the_profile_name_and_avatar(tmp_path, monkeypatch):
    from gateway.chat_slack.provider import profile_identity
    from hermes_cli.profiles import create_profile, get_profile_dir, write_profile_meta
    monkeypatch.setattr("pathlib.Path.home", lambda: tmp_path)
    monkeypatch.setenv("HERMES_HOME", str(tmp_path / ".hermes"))
    create_profile("scout", no_alias=True, no_skills=True)
    home = get_profile_dir("scout")
    assert profile_identity("scout") == ci.BotIdentitySource("scout", "scout", None)
    write_profile_meta(home, display_name="Scout Prime")
    (home / "assets").mkdir()
    (home / "assets" / "avatar.png").write_bytes(b"x")
    assert profile_identity("scout") == ci.BotIdentitySource("scout", "Scout Prime", str(home / "assets" / "avatar.png"))


def test_a_pal_bot_is_a_plain_member_app_not_an_assistant_panel():
    from gateway.chat_slack.provider import bot_manifest
    from tui_gateway.chat_install import IdentityProjection
    projection = IdentityProjection(app_name="Mochi", display_name="Mochi", username="mochi",
                                    avatar_ref=None, avatar_bytes=None)
    manifest = bot_manifest(projection, None, "Mochi on Slack")
    assert "assistant_view" not in manifest["features"] and "agent_view" not in manifest["features"]
    assert "Hermes" not in json.dumps(manifest["display_information"])
    slashes = manifest["features"]["slash_commands"]
    assert "/pal" in {entry["command"] for entry in slashes} and "/hermes" not in {entry["command"] for entry in slashes}
    assert not [entry for entry in slashes if "Hermes" in entry["description"] + entry.get("usage_hint", "")]


def test_the_pal_slash_command_routes_like_the_hermes_one():
    from plugins.platforms.slack.adapter_slash_payload import slash_command_text
    assert slash_command_text({"command": "/pal", "text": "new"}) == slash_command_text({"command": "/hermes", "text": "new"})
    assert slash_command_text({"command": "/pal", "text": "what time is it"}) == "what time is it"
