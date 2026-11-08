"""permissions.*: Auto-Review and the Always Ask / Allow rule lists over the real dispatcher, one profile each."""

from __future__ import annotations

import threading
from pathlib import Path
from types import SimpleNamespace

import pytest

import hermes_cli.config as hermes_config
import hermes_yaml as yaml
from tui_gateway import server


def _write(home: Path, body: str) -> None:
    home.mkdir(parents=True, exist_ok=True)
    (home / "config.yaml").write_text(body, encoding="utf-8")


def _config(home: Path) -> dict:
    return yaml.safe_load((home / "config.yaml").read_text(encoding="utf-8")) or {}


@pytest.fixture
def homes(tmp_path, monkeypatch):
    launch = tmp_path / ".hermes"
    _write(launch, "model:\n  default: launch-model\n")
    _write(launch / "profiles" / "alpha", "model:\n  default: alpha-model\n")
    _write(launch / "profiles" / "beta", "model:\n  default: beta-model\n")
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    monkeypatch.setenv("HERMES_HOME", str(launch))
    monkeypatch.setattr(server, "_hermes_home", launch)
    server._drop_cfg_cache()
    hermes_config._LOAD_CONFIG_CACHE.clear()
    yield SimpleNamespace(launch=launch, alpha=launch / "profiles" / "alpha", beta=launch / "profiles" / "beta")
    server._drop_cfg_cache()
    hermes_config._LOAD_CONFIG_CACHE.clear()


def rpc(method: str, **params) -> dict:
    return server.handle_request({"jsonrpc": "2.0", "id": 1, "method": method, "params": params})


def add(list_name: str, text, **params) -> dict:
    return rpc("permissions.rules.add", list=list_name, text=text, **params)


def refused(response: dict, code: str) -> dict:
    assert response["error"]["code"] == 5320, response
    assert response["error"]["data"]["code"] == code, response
    return response["error"]["data"]


def test_a_fresh_profile_reads_auto_review_on_with_no_rules(homes):
    assert rpc("permissions.get")["result"] == {
        "auto_review": True, "approval_mode": "smart", "ask": [], "allow": []}


def test_rules_round_trip_and_persist_in_that_profiles_config_only(homes):
    ask = add("ask", "  Ask before sending   any email ", profile="alpha")["result"]
    allow = add("allow", "Allow reading files in ~/Projects", profile="alpha")["result"]

    assert ask["text"] == "Ask before sending any email"
    assert ask["id"] and ask["created_at"].endswith("Z")
    state = rpc("permissions.get", profile="alpha")["result"]
    assert state["ask"] == [ask] and state["allow"] == [allow]
    assert _config(homes.alpha)["approvals"]["rules"] == {"ask": [ask], "allow": [allow]}
    assert "approvals" not in _config(homes.beta) and "approvals" not in _config(homes.launch)
    assert rpc("permissions.get", profile="beta")["result"]["ask"] == []
    assert rpc("permissions.get")["result"]["allow"] == []

    assert rpc("permissions.rules.remove", id=ask["id"], profile="alpha")["result"] == {"removed": True}
    after = rpc("permissions.get", profile="alpha")["result"]
    assert after["ask"] == [] and after["allow"] == [allow]
    assert _config(homes.alpha)["approvals"]["rules"]["ask"] == []


def test_two_profiles_keep_independent_rules_and_toggles(homes):
    add("ask", "Ask before deleting files", profile="alpha")
    add("allow", "Allow running tests", profile="beta")
    assert rpc("permissions.set_auto_review", enabled=False, profile="beta")["result"]["auto_review"] is False

    alpha = rpc("permissions.get", profile="alpha")["result"]
    beta = rpc("permissions.get", profile="beta")["result"]
    assert (alpha["auto_review"], [r["text"] for r in alpha["ask"]], alpha["allow"]) == (
        True, ["Ask before deleting files"], [])
    assert (beta["auto_review"], beta["ask"], [r["text"] for r in beta["allow"]]) == (
        False, [], ["Allow running tests"])
    assert _config(homes.beta)["approvals"]["mode"] == "manual"
    assert "mode" not in _config(homes.alpha)["approvals"]


def test_an_unknown_profile_is_an_error_and_writes_nothing(homes):
    before = (homes.launch / "config.yaml").read_bytes()
    assert rpc("permissions.get", profile="ghost")["error"]["code"] == 4064
    assert add("ask", "Ask before anything", profile="ghost")["error"]["code"] == 4064
    assert (homes.launch / "config.yaml").read_bytes() == before


def test_auto_review_toggles_between_smart_and_manual_and_is_idempotent(homes):
    off = rpc("permissions.set_auto_review", enabled=False)["result"]
    assert (off["auto_review"], off["approval_mode"]) == (False, "manual")
    assert _config(homes.launch)["approvals"]["mode"] == "manual"
    stamp = (homes.launch / "config.yaml").stat().st_mtime_ns
    assert rpc("permissions.set_auto_review", enabled=False)["result"] == off
    assert (homes.launch / "config.yaml").stat().st_mtime_ns == stamp
    on = rpc("permissions.set_auto_review", enabled=True)["result"]
    assert (on["auto_review"], on["approval_mode"]) == (True, "smart")
    assert _config(homes.launch)["approvals"]["mode"] == "smart"


@pytest.mark.parametrize("written", ["off", '"off"'])
def test_the_toggle_never_writes_the_mode_that_skips_approvals(homes, written):
    _write(homes.alpha, f"approvals:\n  mode: {written}\n")
    server._drop_cfg_cache()
    hermes_config._LOAD_CONFIG_CACHE.clear()

    state = rpc("permissions.get", profile="alpha")["result"]
    assert (state["auto_review"], state["approval_mode"]) == (False, "off")
    unchanged = rpc("permissions.set_auto_review", enabled=False, profile="alpha")["result"]
    assert unchanged["approval_mode"] == "off"
    assert _config(homes.alpha)["approvals"]["mode"] in ("off", False)
    turned_on = rpc("permissions.set_auto_review", enabled=True, profile="alpha")["result"]
    assert (turned_on["auto_review"], turned_on["approval_mode"]) == (True, "smart")


@pytest.mark.parametrize("enabled", ["yes", 1, None])
def test_auto_review_needs_a_boolean(homes, enabled):
    refused(rpc("permissions.set_auto_review", enabled=enabled), "invalid_enabled")
    assert "approvals" not in _config(homes.launch)


@pytest.mark.parametrize("text, code", [
    ("", "empty_text"), ("   \n\t ", "empty_text"), (None, "invalid_text"), (7, "invalid_text"),
    ("x" * 281, "text_too_long"), ("a\x00b", "invalid_text"), ("a\x1bb", "invalid_text")])
def test_unusable_rule_text_is_rejected_and_stores_nothing(homes, text, code):
    refused(add("ask", text), code)
    assert "approvals" not in _config(homes.launch)


def test_rule_text_is_trimmed_to_one_line_and_capped_at_280(homes):
    longest = add("allow", f"  {'x' * 280}  ")["result"]
    assert len(longest["text"]) == 280
    multi = add("ask", "Ask before\nrunning anything\r\nas root")["result"]
    assert multi["text"] == "Ask before running anything as root"


def test_a_repeated_rule_is_rejected_in_either_list_and_names_the_existing_one(homes):
    first = add("ask", "Ask before sending any email")["result"]
    same_list = refused(add("ask", "ask  before SENDING any email"), "duplicate_rule")
    other_list = refused(add("allow", "Ask before sending any email"), "duplicate_rule")
    assert same_list["list"] == other_list["list"] == "ask"
    assert same_list["rule"] == other_list["rule"] == first
    assert len(rpc("permissions.get")["result"]["ask"]) == 1 and rpc("permissions.get")["result"]["allow"] == []


@pytest.mark.parametrize("list_name", ["deny", "", None, 3])
def test_only_ask_and_allow_are_lists(homes, list_name):
    refused(add(list_name, "Ask before anything"), "invalid_list")


def test_a_list_holds_at_most_thirty_rules(homes):
    for index in range(30):
        add("ask", f"Ask before action number {index}")
    refused(add("ask", "One rule too many"), "limit_reached")
    assert add("allow", "The allow list has its own room")["result"]["id"]
    assert len(rpc("permissions.get")["result"]["ask"]) == 30


def test_removing_an_unknown_id_is_a_no_op_and_writes_nothing(homes):
    add("ask", "Ask before sending any email")
    stamp = (homes.launch / "config.yaml").stat().st_mtime_ns
    assert rpc("permissions.rules.remove", id="nope")["result"] == {"removed": False}
    assert (homes.launch / "config.yaml").stat().st_mtime_ns == stamp
    refused(rpc("permissions.rules.remove", id="  "), "invalid_id")
    refused(rpc("permissions.rules.remove", id=None), "invalid_id")


def test_removing_twice_converges(homes):
    rule = add("allow", "Allow reading files in ~/Projects")["result"]
    assert rpc("permissions.rules.remove", id=rule["id"])["result"] == {"removed": True}
    assert rpc("permissions.rules.remove", id=rule["id"])["result"] == {"removed": False}
    assert rpc("permissions.get")["result"]["allow"] == []


def test_unknown_params_are_rejected(homes):
    assert rpc("permissions.get", bogus=1)["error"]["code"] == 4000
    assert add("ask", "Ask before anything", extra=1)["error"]["code"] == 4000


def test_hand_edited_entries_are_ignored_on_read_and_kept_on_write(homes):
    _write(homes.launch, "approvals:\n  rules:\n    ask:\n      - just a string\n      - {id: keep, text: Ask before email}\n"
                         "      - {id: blank, text: '  '}\n    allow: not-a-list\n")
    server._drop_cfg_cache()
    hermes_config._LOAD_CONFIG_CACHE.clear()
    state = rpc("permissions.get")["result"]
    assert [rule["id"] for rule in state["ask"]] == ["keep"] and state["allow"] == []

    add("ask", "Ask before deleting files")
    kept = _config(homes.launch)["approvals"]["rules"]["ask"]
    assert kept[0] == "just a string" and kept[2] == {"id": "blank", "text": "  "}
    assert len(kept) == 4


def test_an_unreadable_config_is_never_overwritten(homes):
    garbage = b"approvals: [unclosed\n  - : :"
    (homes.alpha / "config.yaml").write_bytes(garbage)
    server._drop_cfg_cache()
    hermes_config._LOAD_CONFIG_CACHE.clear()
    refused(add("ask", "Ask before anything", profile="alpha"), "config_unreadable")
    assert (homes.alpha / "config.yaml").read_bytes() == garbage


def test_concurrent_adds_all_land_and_a_concurrent_repeat_lands_once(homes):
    texts = [f"Ask before action number {index}" for index in range(12)]
    results: list[dict] = []
    barrier = threading.Barrier(len(texts) + 4)

    def worker(text):
        barrier.wait()
        results.append(add("ask", text))

    threads = [threading.Thread(target=worker, args=(text,)) for text in texts]
    threads += [threading.Thread(target=worker, args=("Allow the same thing",)) for _ in range(4)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()

    stored = [rule["text"] for rule in rpc("permissions.get")["result"]["ask"]]
    assert sorted(stored) == sorted([*texts, "Allow the same thing"])
    assert sum("result" in response for response in results) == len(texts) + 1


def test_changing_rules_does_not_change_the_agents_system_prompt(homes):
    from agent.system_prompt import build_system_prompt

    def prompt():
        agent = SimpleNamespace(
            load_soul_identity=False, skip_context_files=True, valid_tool_names=[], _task_completion_guidance=False,
            _tool_use_enforcement=False, _environment_probe=False, _kanban_worker_guidance="", _memory_store=None,
            _memory_manager=None, model="", provider="", platform="", pass_session_id=False, session_id="",
            _emit_status=lambda *_a, **_k: None, _emit_diagnostic_status=lambda *_a, **_k: None)
        return build_system_prompt(agent)

    from unittest.mock import patch
    with patch("agent.system_prompt._timestamp_line", return_value="timestamp"):
        before = prompt()
        add("ask", "Ask before sending any email")
        add("allow", "Allow reading files in ~/Projects")
        rpc("permissions.set_auto_review", enabled=False)
        after = prompt()
    assert before == after
    assert "sending any email" not in after
