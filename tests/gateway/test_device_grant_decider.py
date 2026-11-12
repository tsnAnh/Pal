from dataclasses import replace
from pathlib import Path

import pytest

from gateway.session_iphone_toolset import (
    GRANTED_KINDS, GrantReason, SessionFacts, SessionKind, decide_grant)
from tests.gateway.test_device_tools_session_kinds import (
    DEVICE_TOOLS, KINDS, offered, sessions, switch_mac)

pytest_plugins = ('tests.gateway.device_tools_harness',)


def facts(home, kind=SessionKind.DESKTOP, **over):
    base = dict(kind=kind, picked_toolsets=False, safe_mode=False, disabled_toolsets=frozenset(), profile_home=Path(home))
    return SessionFacts(**{**base, **over})


@pytest.mark.parametrize('kind', list(SessionKind))
def test_only_the_granted_kinds_get_the_tools_and_only_with_a_registered_device(tmp_path, kind):
    assert decide_grant(facts(tmp_path, kind)).reason is GrantReason.NO_REGISTERED_DEVICE if kind in GRANTED_KINDS \
        else decide_grant(facts(tmp_path, kind)).reason is GrantReason.KIND_NOT_ALLOWED
    switch_mac(tmp_path, True)
    assert decide_grant(facts(tmp_path, kind)).granted is (kind in GRANTED_KINDS)


def test_every_exclusion_names_its_reason_and_wins_over_a_registered_device(tmp_path):
    switch_mac(tmp_path, True)
    assert decide_grant(facts(tmp_path, picked_toolsets=True)).reason is GrantReason.EXPLICIT_PICK
    assert decide_grant(facts(tmp_path, safe_mode=True)).reason is GrantReason.SAFE_MODE
    assert decide_grant(facts(tmp_path, disabled_toolsets=frozenset({'iphone'}))).reason is GrantReason.DISABLED_BY_CONFIG


def test_an_unreadable_device_store_fails_closed(tmp_path):
    (tmp_path / 'device_connectors.json').write_text('{not json')
    assert decide_grant(facts(tmp_path)).reason is GrantReason.NO_REGISTERED_DEVICE


def test_a_device_registered_in_another_profile_is_not_seen(tmp_path):
    mine, theirs = tmp_path / 'mine', tmp_path / 'theirs'
    mine.mkdir(), theirs.mkdir()
    switch_mac(theirs, True)
    assert decide_grant(facts(mine)).reason is GrantReason.NO_REGISTERED_DEVICE
    assert decide_grant(facts(theirs)).granted


@pytest.mark.asyncio
async def test_a_desktop_chat_that_started_without_a_device_gets_the_tools_on_the_turn_one_appears_and_keeps_them(
        tmp_path, monkeypatch):
    store, authority, owner, made = await sessions(tmp_path, monkeypatch, {'desktop': KINDS['desktop']}, False)
    try:
        policy, session_id = made['desktop']
        assert offered(authority, policy, session_id) == set()
        assert authority.sessions[session_id].iphone_toolset is None
        for home in (tmp_path / 'home', tmp_path / authority.profile_id):
            switch_mac(home, True)
        assert offered(authority, policy, session_id) == DEVICE_TOOLS
        assert authority.sessions[session_id].iphone_toolset is True
        for home in (tmp_path / 'home', tmp_path / authority.profile_id):
            switch_mac(home, False)
        assert offered(authority, policy, session_id) == DEVICE_TOOLS
    finally:
        await owner.close()
        store.close_all_db_handles()


@pytest.mark.asyncio
async def test_an_ineligible_chat_is_cached_negative_and_never_flips(tmp_path, monkeypatch):
    store, authority, owner, made = await sessions(
        tmp_path, monkeypatch, {'picked': dict(source='gui', toolsets=['web'])}, False)
    try:
        policy, session_id = made['picked']
        assert offered(authority, policy, session_id) == set()
        assert authority.sessions[session_id].iphone_toolset is False
        for home in (tmp_path / 'home', tmp_path / authority.profile_id):
            switch_mac(home, True)
        assert offered(authority, policy, session_id) == set()
    finally:
        await owner.close()
        store.close_all_db_handles()


@pytest.mark.asyncio
@pytest.mark.parametrize('name', ['desktop', 'cli', 'bot_chat'])
async def test_safe_mode_sessions_are_never_offered_the_tools(tmp_path, monkeypatch, name):
    store, authority, owner, made = await sessions(tmp_path, monkeypatch, {name: KINDS[name]}, True)
    try:
        policy, session_id = made[name]
        assert offered(authority, replace(policy, safe_mode=True), session_id) == set()
    finally:
        await owner.close()
        store.close_all_db_handles()


@pytest.mark.asyncio
async def test_a_desktop_chat_with_iphone_disabled_in_the_profile_config_is_not_offered_the_tools(tmp_path, monkeypatch):
    from gateway.session_policy import policy_turn_toolsets
    store, authority, owner, made = await sessions(tmp_path, monkeypatch, {'desktop': KINDS['desktop']}, True)
    try:
        policy, session_id = made['desktop']
        config = {'agent': {'disabled_toolsets': ['iphone']}}
        assert 'iphone' not in policy_turn_toolsets(authority, policy, config, session_id)
    finally:
        await owner.close()
        store.close_all_db_handles()
