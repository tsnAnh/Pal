import json

import pytest

from tools.bot_desktop import lease


@pytest.fixture
def fresh_lease():
    lease._reset_for_tests()
    yield lease
    lease._reset_for_tests()


@pytest.fixture
def managed(monkeypatch):
    import tools.bot_handback_tool as tool

    monkeypatch.setattr(tool, "_is_bot_managed", lambda home=None: True)
    return tool


def test_request_lands_on_the_lease_and_is_broadcast(fresh_lease):
    seen = []
    off = fresh_lease.on_change(lambda key, value: seen.append(value))
    try:
        pending = fresh_lease.request_handback("  Sign in to\nExample to continue ")
    finally:
        off()
    assert pending.ask == "Sign in to Example to continue"
    assert pending.ask_at > 0
    assert pending.holder == fresh_lease.AGENT
    assert [v.ask for v in seen] == ["Sign in to Example to continue"]
    assert fresh_lease.get().ask == pending.ask


def test_ask_is_capped_and_public(fresh_lease):
    pending = fresh_lease.request_handback("x" * 1000)
    assert len(pending.ask) == fresh_lease.MAX_ASK_CHARS
    view = fresh_lease.public_view(pending)
    assert view["ask"] == pending.ask and view["ask_at"] == pending.ask_at


def test_ask_survives_takeover_and_release_until_resolved(fresh_lease):
    asked = fresh_lease.request_handback("Solve the CAPTCHA")
    fresh_lease.acquire("viewer-1", reason=asked.ask)
    assert fresh_lease.get().ask == "Solve the CAPTCHA"
    assert fresh_lease.get().reason == "Solve the CAPTCHA"
    fresh_lease.release("viewer-1")
    still = fresh_lease.get()
    assert still.holder == fresh_lease.AGENT and still.ask == "Solve the CAPTCHA"
    resolved = fresh_lease.resolve_ask(ask_at=asked.ask_at)
    assert resolved.ask == "" and resolved.ask_at == 0.0


def test_resolve_ignores_a_stale_card_and_a_missing_ask(fresh_lease):
    first = fresh_lease.request_handback("Sign in")
    second = fresh_lease.request_handback("Enter the code")
    epoch = fresh_lease.get().epoch
    assert fresh_lease.resolve_ask(ask_at=first.ask_at).ask == "Enter the code"
    assert fresh_lease.get().epoch == epoch
    assert fresh_lease.resolve_ask(ask_at=second.ask_at).ask == ""
    epoch = fresh_lease.get().epoch
    fresh_lease.resolve_ask()
    assert fresh_lease.get().epoch == epoch


def test_tool_records_the_ask_and_tells_the_model_to_stop(fresh_lease, managed):
    out = json.loads(managed.request_handback_tool("Sign in to Example to continue"))
    assert out["success"] and out["status"] == "waiting_for_person"
    assert out["reason"] == "Sign in to Example to continue"
    assert out["requested_at"] == fresh_lease.get().ask_at
    assert out["person_in_control"] is False
    assert "End your turn" in out["next"]


def test_tool_reports_a_person_already_in_control(fresh_lease, managed):
    fresh_lease.acquire("viewer-1")
    out = json.loads(managed.request_handback_tool("Sign in"))
    assert out["person_in_control"] is True
    assert fresh_lease.get().holder == fresh_lease.HUMAN


def test_tool_refuses_an_empty_reason(fresh_lease, managed):
    out = json.loads(managed.request_handback_tool("   "))
    assert "reason is required" in out["error"]
    assert fresh_lease.get().ask == ""


def test_tool_is_offered_only_to_bot_profiles(monkeypatch, tmp_path):
    import tools.bot_handback_tool as tool
    from toolsets import _HERMES_CORE_TOOLS, TOOLSETS

    assert "request_handback" in TOOLSETS["desktop_ui"]["tools"]
    assert "request_handback" not in _HERMES_CORE_TOOLS
    root = tmp_path / ".hermes"
    bot = root / "profiles" / "scout"
    plain = root / "profiles" / "work"
    bot.mkdir(parents=True)
    plain.mkdir(parents=True)
    (bot / "profile.yaml").write_text("ui_meta:\n  hermes-bots:\n    shape: cloud\n", encoding="utf-8")

    monkeypatch.setattr(tool, "get_hermes_home", lambda: str(plain))
    assert tool.check_request_handback() is False
    monkeypatch.setattr(tool, "get_hermes_home", lambda: str(bot))
    assert tool.check_request_handback() is True


def test_bot_prompt_says_to_hand_back_instead_of_bypassing():
    from tools.bot_mode_probe import _HANDBACK_PARAGRAPH

    assert "request_handback" in _HANDBACK_PARAGRAPH
    assert "CAPTCHA" in _HANDBACK_PARAGRAPH and "Never try" in _HANDBACK_PARAGRAPH


def _rpc(method, params):
    from tui_gateway import server

    return server.handle_request({"jsonrpc": "2.0", "id": 3, "method": method, "params": params})


def test_resolve_rpc_clears_only_the_named_ask(fresh_lease):
    asked = fresh_lease.request_handback("Sign in")
    stale = _rpc("display.lease.resolve", {"ask_at": asked.ask_at - 1})
    assert stale["result"]["lease"]["ask"] == "Sign in"
    done = _rpc("display.lease.resolve", {"ask_at": asked.ask_at})
    assert done["result"]["lease"]["ask"] == ""


def test_resolve_rpc_rejects_a_malformed_ask_at(fresh_lease):
    fresh_lease.request_handback("Sign in")
    bad = _rpc("display.lease.resolve", {"ask_at": "soon"})
    assert bad["error"]["data"]["code"] == "bad_ask_at"
    assert fresh_lease.get().ask == "Sign in"
