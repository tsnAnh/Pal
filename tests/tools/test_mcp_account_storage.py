from __future__ import annotations

import asyncio
import os
import stat

import pytest

from hermes_constants import get_hermes_home
from tools.mcp_oauth import HermesTokenStorage

pytest.importorskip("mcp.client.auth.oauth2")


def put(name: str, access_token: str) -> HermesTokenStorage:
    from mcp.shared.auth import OAuthToken
    storage = HermesTokenStorage(name)
    asyncio.run(storage.set_tokens(OAuthToken(access_token=access_token, token_type="Bearer", expires_in=3600)))
    return storage


def read(name: str) -> str:
    return asyncio.run(HermesTokenStorage(name).get_tokens()).access_token


def test_pairs_that_read_alike_never_share_a_file():
    names = ["a@b-c", "a-b@c", "a_b@c", "a_b_c", "a@b", "a_b", "a-b_c", "a_@c", "a@c"]
    for name in names:
        put(name, f"token-of-{name}")

    assert {name: read(name) for name in names} == {name: f"token-of-{name}" for name in names}


def test_an_accounts_files_sit_in_its_connectors_directory_and_stay_private():
    storage = put("linear@work", "tok")
    storage.mark_reauth_required()
    account_dir = get_hermes_home() / "mcp-tokens" / "accounts" / "linear"

    assert {p.name for p in account_dir.iterdir()} >= {"work.json", "work.reauth"}
    assert not (get_hermes_home() / "mcp-tokens" / "linear_work.json").exists()
    if os.name == "posix":
        assert stat.S_IMODE((account_dir / "work.json").stat().st_mode) == 0o600
        for directory in (account_dir, account_dir.parent, account_dir.parent.parent):
            assert stat.S_IMODE(directory.stat().st_mode) == 0o700, directory


def test_removing_one_account_leaves_the_others_and_a_plain_server_alone():
    for name in ("linear@work", "linear@home", "linear", "custom"):
        put(name, f"token-of-{name}")

    from tools.mcp_oauth import remove_oauth_tokens
    remove_oauth_tokens("linear@work")

    assert not HermesTokenStorage("linear@work").has_cached_tokens()
    assert [read(n) for n in ("linear@home", "linear", "custom")] == ["token-of-linear@home", "token-of-linear", "token-of-custom"]


def test_purging_an_account_removes_every_state_file_and_its_empty_directory():
    work = put("linear@work", "tok")
    work.mark_reauth_required()
    work.update_redirect_pref(redirect="app")
    HermesTokenStorage("linear@home").mark_reauth_required()

    work.purge()

    assert work.state_paths() == []
    assert HermesTokenStorage("linear@home").reauth_required()
    HermesTokenStorage("linear@home").purge()
    assert not (get_hermes_home() / "mcp-tokens" / "accounts" / "linear").exists()


def test_re_authorizing_one_account_keeps_the_other_accounts_tokens():
    put("linear@work", "old-work")
    put("linear@home", "home")
    work = HermesTokenStorage("linear@work")
    before = work.snapshot()

    work.remove()
    put("linear@work", "new-work")

    assert read("linear@work") == "new-work" and read("linear@home") == "home"
    work.restore(before)
    assert read("linear@work") == "old-work" and read("linear@home") == "home"


@pytest.mark.asyncio
async def test_a_token_file_rewrite_is_noticed_per_account():
    from mcp.shared.auth import OAuthToken

    from tools.mcp_oauth_manager import MCPOAuthManager, reset_manager_for_tests
    reset_manager_for_tests()
    for name, access_token in (("linear@work", "one"), ("linear@home", "other")):
        await HermesTokenStorage(name).set_tokens(OAuthToken(access_token=access_token, token_type="Bearer", expires_in=3600))
    manager = MCPOAuthManager()
    work = manager.get_or_build_provider("linear@work", "https://example.com/mcp", None)
    home = manager.get_or_build_provider("linear@home", "https://example.com/mcp", None)
    await work._initialize()
    await home._initialize()
    assert await manager.invalidate_if_disk_changed("linear@work") is False
    assert await manager.invalidate_if_disk_changed("linear@home") is False

    await HermesTokenStorage("linear@work").set_tokens(
        OAuthToken(access_token="two", token_type="Bearer", expires_in=3600, refresh_token="rotated"))

    assert await manager.invalidate_if_disk_changed("linear@work") is True
    assert await manager.invalidate_if_disk_changed("linear@home") is False
    assert manager.evict("linear@work") is not None
    assert manager.evict("linear@work") is None
    assert manager.evict("linear@home") is not None


def test_api_key_variables_of_different_pairs_differ():
    from tools.mcp_accounts import api_key_env

    assert api_key_env("a", "b-c") != api_key_env("a-b", "c")
