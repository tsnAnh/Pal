"""``gateway.bot_loop_guard.*`` edits apply to the next check without a restart, the hard limits in code
clamp every value, and a bad value never switches the guard off."""

import json
import types

import pytest

from gateway import bot_loop_guard
from gateway.bot_loop_guard import MAX_HOPS_CAP, BotLoopGuard, load_settings, resolve_config


@pytest.fixture(autouse=True)
def fresh_warnings():
    bot_loop_guard._warned.clear()


@pytest.fixture
def home(tmp_path, monkeypatch):
    path = tmp_path / "home"
    path.mkdir()
    monkeypatch.setenv("HERMES_HOME", str(path))

    def write(block) -> None:
        (path / "config.yaml").write_text(json.dumps({"gateway": {"bot_loop_guard": block}}), encoding="utf-8")
    write.path = path
    return write


def hops(raw) -> int:
    return resolve_config({"gateway": {"bot_loop_guard": {"max_hops": raw}}})["max_hops"].value


def test_next_bot_message_uses_the_edited_max_hops_without_a_restart(home, monkeypatch):
    from agent import bot_chain

    monkeypatch.setattr(bot_chain, "_CHAINS", {})
    home({"max_hops": 2})
    guard = BotLoopGuard()
    agent = types.SimpleNamespace(session_id="s-live", _turn_author={"id": "bot:alpha", "name": "alpha", "is_bot": True})
    bot_chain.on_turn_start(agent, agent._turn_author, None, "hi")
    assert [guard.chain_admit("c", "peer", f"m{n}", is_bot=True)[1] for n in range(3)] == ["ok", "ok", "max_hops"]
    assert bot_chain.admit_send(agent, ["bot:x"], "one").refusal is None
    assert "limit of 2 messages" in str(bot_chain.admit_send(agent, ["bot:y"], "two").refusal)

    home({"max_hops": 6})
    assert load_settings().max_hops == 6
    assert guard.chain_admit("c", "peer", "m3", is_bot=True)[1] == "ok"
    assert bot_chain.admit_send(agent, ["bot:y"], "two").refusal is None


@pytest.mark.parametrize("raw", [0, -1, "ten", None, True, False, 2.5, float("inf"), float("nan"), [], {}])
def test_unusable_max_hops_fall_back_to_the_default_and_never_disable_the_guard(raw):
    item = resolve_config({"gateway": {"bot_loop_guard": {"max_hops": raw}}})["max_hops"]
    assert (item.value, item.source, item.clamped) == (4, "default", False)


@pytest.mark.parametrize("raw,expected", [(1000, MAX_HOPS_CAP), (MAX_HOPS_CAP + 1, MAX_HOPS_CAP), (MAX_HOPS_CAP, MAX_HOPS_CAP), (10, 10), ("10", 10), (1, 1)])
def test_max_hops_is_clamped_to_the_hard_limit(raw, expected):
    item = resolve_config({"gateway": {"bot_loop_guard": {"max_hops": raw}}})["max_hops"]
    assert (item.value, item.source, item.clamped) == (expected, "config", raw not in (expected, str(expected)))


def test_the_hard_cap_holds_through_the_guard(home):
    home({"max_hops": 1000})
    guard = BotLoopGuard()
    states = [guard.chain_admit("c", "peer", f"m{n}", is_bot=True)[1] for n in range(MAX_HOPS_CAP + 1)]
    assert states.count("ok") == MAX_HOPS_CAP and states[-1] == "max_hops"


def test_missing_block_is_the_default_without_a_warning(monkeypatch):
    seen = []
    monkeypatch.setattr(bot_loop_guard.logger, "warning", lambda fmt, *args: seen.append(fmt))
    resolved = resolve_config({})
    assert all(item.source == "default" and not item.clamped for item in resolved.values())
    assert resolved["max_hops"].value == 4 and resolved["enabled"].value is True
    assert not seen


def test_every_numeric_key_is_clamped_and_a_typo_in_enabled_keeps_the_guard_on():
    block = {"max_events": 10**9, "window_seconds": "x", "cooldown_seconds": 10**9, "enabled": "maybe", "bot_replies_expect_reply": "perhaps"}
    resolved = resolve_config({"gateway": {"bot_loop_guard": block}})
    assert (resolved["max_events"].value, resolved["max_events"].clamped) == (1000, True)
    assert (resolved["cooldown_seconds"].value, resolved["cooldown_seconds"].clamped) == (86400.0, True)
    assert resolved["window_seconds"].source == "default" and resolved["window_seconds"].value == 300.0
    assert resolved["enabled"].value is True and resolved["enabled"].source == "default"
    assert resolved["bot_replies_expect_reply"].value is False
    assert resolve_config({"gateway": {"bot_loop_guard": {"enabled": False}}})["enabled"].value is False


def test_one_warning_per_distinct_bad_value(monkeypatch):
    seen = []
    monkeypatch.setattr(bot_loop_guard.logger, "warning", lambda fmt, *args: seen.append(fmt % args))
    for _ in range(3):
        hops("ten")
    hops(0)
    hops("ten")
    assert len(seen) == 2 and "'ten'" in seen[0] and "max_hops" in seen[0]


def test_guard_consults_the_profile_whose_config_is_bound(tmp_path, monkeypatch):
    for name, value in (("alpha", 3), ("beta", 9)):
        profile = tmp_path / name
        profile.mkdir()
        (profile / "config.yaml").write_text(json.dumps({"gateway": {"bot_loop_guard": {"max_hops": value}}}), encoding="utf-8")
    monkeypatch.setenv("HERMES_HOME", str(tmp_path / "alpha"))
    assert load_settings().max_hops == 3
    monkeypatch.setenv("HERMES_HOME", str(tmp_path / "beta"))
    assert load_settings().max_hops == 9


def test_managed_worker_config_carries_the_live_guard_block(tmp_path, monkeypatch):
    from gateway import session_managed_worker

    profile = tmp_path / "profile"
    profile.mkdir()
    (profile / "config.yaml").write_text(json.dumps({"gateway": {"bot_loop_guard": {"max_hops": 10}}}), encoding="utf-8")
    frozen = {"gateway": {"managed_workers": True, "bot_loop_guard": {"max_hops": 4}}, "agent": {"max_turns": 7}}
    policy = types.SimpleNamespace(ignore_user_config=False, config=lambda authority: json.loads(json.dumps(frozen)))
    authority = types.SimpleNamespace(profile_id=str(profile))
    config = session_managed_worker._worker_config(authority, policy)
    assert config["gateway"] == {"managed_workers": True, "bot_loop_guard": {"max_hops": 10}}
    assert config["agent"] == {"max_turns": 7}
    assert frozen["gateway"]["bot_loop_guard"] == {"max_hops": 4}

    bypass = types.SimpleNamespace(ignore_user_config=True, config=lambda authority: json.loads(json.dumps(frozen)))
    assert session_managed_worker._worker_config(authority, bypass)["gateway"]["bot_loop_guard"] == {"max_hops": 4}
