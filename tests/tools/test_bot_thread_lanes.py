import argparse
import json
import subprocess

import pytest

from hermes_state import SessionDB
from tests.tools.test_bot_mode_dm import _capture_spawn, _FakeAgent, _managed_home, _runner_parts
from tools import bot_mode_dm, bot_mode_probe, bot_relay
from tools import bot_thread_identity as identity
from tools import bot_thread_ledger as ledger
from tools.bot_thread_ledger import PageRequest


@pytest.fixture(autouse=True)
def _fresh_probe_cache():
    bot_mode_probe._reset_cache_for_tests()
    yield
    bot_mode_probe._reset_cache_for_tests()


def _messages(home, thread_id):
    page = ledger.read_page(home, thread_id, PageRequest(limit=20))
    return [] if page is None else [(m.part.value, m.body, m.status.value) for m in page.messages]


def test_relay_send_is_pending_until_the_first_reply_lands_and_joins_the_inbound_thread(tmp_path, monkeypatch):
    _capture_spawn(monkeypatch)
    home = _managed_home(tmp_path)
    row = {"profile": "scout", "handle": "scout", "connection_id": "mini", "connection_label": "Mini"}
    bot_relay.write_remote_roster(home, [row])
    ack = json.loads(bot_mode_dm.message_agent_tool(target="scout@mini", message="ping", agent=_FakeAgent(home)))
    counterpart = identity.outbound_relay(bot_relay.read_remote_roster(home)[0])
    assert _messages(home, counterpart.thread_id) == [("message", "ping", "pending")]

    bot_relay.write_reply(home, ack["delivery_id"], reply="pong")
    rev = ledger.read_page(home, counterpart.thread_id, PageRequest(limit=5)).rev
    bot_relay.write_reply(home, ack["delivery_id"], error="late duplicate", reason="delivery_timeout")
    assert _messages(home, counterpart.thread_id) == [("message", "ping", "answered"), ("reply", "pong", "answered")]
    assert ledger.read_page(home, counterpart.thread_id, PageRequest(limit=5)).rev == rev
    relayed = identity.inbound({"id": "bot:mini/scout", "name": "scout", "is_bot": True}, None,
                               bot_relay.read_remote_roster(home))
    assert relayed.thread_id == counterpart.thread_id


def test_a_relay_principal_sender_resolves_through_its_stamp_and_the_roster():
    roster = [{"profile": "scout", "handle": "scout", "connection_id": "mini", "connection_label": "Mini"},
              {"profile": "chef", "handle": "chef", "connection_id": "mini", "connection_label": "Mini"}]
    from tools.bot_dm_wire import split_sender_stamp
    principal = {"id": "bot:relay/abc123", "name": "relayed teammate", "is_bot": True}
    scout = identity.inbound(principal, split_sender_stamp("Message from 🤖 Scout (@scout@mini): hi"), roster)
    chef = identity.inbound(principal, split_sender_stamp("Message from 🤖 Chef (@chef): hi"), roster)
    stranger = identity.inbound(principal, split_sender_stamp("Message from 🤖 Who (@who): hi"), roster)
    assert (scout.key, chef.key, stranger.key) == ("remote:mini/scout", "remote:mini/chef", "remote:relay/who")
    assert scout.attribution == identity.Attribution.stamp
    assert identity.inbound({"id": "user:1", "is_bot": False}, None, roster) is None


def test_peer_send_learns_the_peer_origin_from_the_result_file(tmp_path, monkeypatch):
    calls = _capture_spawn(monkeypatch)
    monkeypatch.setattr(bot_relay, "_hermes_cli", lambda: "hermes")
    home = _managed_home(tmp_path, peers=("spark",))
    monkeypatch.setattr(bot_mode_dm, "_dm_dir", lambda: tmp_path)
    ack = json.loads(bot_mode_dm.message_agent_tool(target="spark/researcher", message="status?",
                                                    agent=_FakeAgent(home)))
    provisional = identity.outbound_peer("spark", "researcher", None)
    assert _messages(home, provisional.thread_id) == [("message", "status?", "pending")]
    mode, dm_file, argv, _profile_home = _runner_parts(calls[0]["command"])
    assert "--ledger-home" in calls[0]["command"] and mode == "stdin"

    def peer(argv, **kwargs):
        path = argv[argv.index("--result-file") + 1]
        with open(path, "w", encoding="utf-8") as stream:
            json.dump({"status": "settled", "reply": "all green", "origin": "spark-host", "reason": None}, stream)
        return subprocess.CompletedProcess(argv, 0)

    monkeypatch.setattr(subprocess, "run", peer)
    assert bot_mode_dm._run_delivery(argv, dm_file, stdin_file=True, ledger_home=home) == 0
    learned = identity.outbound_peer("spark", "researcher", ledger.peer_origin(home, "spark"))
    assert learned.key == "remote:spark-host/researcher"
    assert _messages(home, learned.thread_id) == [("message", "status?", "answered"), ("reply", "all green", "answered")]
    assert ack["delivery_id"] == ledger.read_page(home, learned.thread_id, PageRequest(limit=5)).messages[0].exchange_id[4:]


@pytest.mark.parametrize("response, expected", [
    ({"message": {"content": "all green"}, "origin": "spark-host"},
     {"status": "settled", "reply": "all green", "origin": "spark-host", "reason": None}),
    ({"object": "hermes.session.chat.queued", "status": "queued", "origin": "spark-host"},
     {"status": "queued", "reply": "", "origin": "spark-host", "reason": None}),
    ({"message": {"content": "NO_REPLY"}}, {"status": "settled", "reply": "", "origin": None, "reason": None}),
])
def test_peer_dm_result_file_mirrors_its_stdout_decision(tmp_path, monkeypatch, capsys, response, expected):
    from hermes_cli.subcommands import peer
    monkeypatch.setattr(peer, "_ensure_bot_chat", lambda base, key: "bot-chat")
    monkeypatch.setattr(peer, "_request", lambda *a, **k: response)
    result_file = tmp_path / "result.json"
    args = argparse.Namespace(json=False, result_file=str(result_file))
    assert peer._peer_dm(args, "hi", "spark", "researcher", "http://spark", "key") == 0
    assert json.loads(result_file.read_text(encoding="utf-8")) == expected
    assert result_file.stat().st_mode & 0o777 == 0o600


def test_peer_dm_unreachable_writes_a_failed_result(tmp_path, monkeypatch):
    from hermes_cli.subcommands import peer

    def unreachable(*a, **k):
        raise OSError("connection refused")
    monkeypatch.setattr(peer, "_ensure_bot_chat", unreachable)
    result_file = tmp_path / "result.json"
    assert peer._peer_dm(argparse.Namespace(json=False, result_file=str(result_file)), "hi", "spark", None,
                         "http://spark", "key") == 1
    assert json.loads(result_file.read_text(encoding="utf-8"))["status"] == "failed"


def test_api_server_direct_peer_turn_records_the_inbound_exchange_without_a_chat_link(tmp_path):
    from gateway.platforms.api_server_peer_threads import open_direct_peer_exchange
    db = SessionDB(db_path=tmp_path / "state.db")
    try:
        db.create_session("chat-1", source="api_server")
        db.set_session_title("chat-1", "Bot Chat")
        author = {"id": "bot:laptop/default", "name": "hermes", "is_bot": True}
        assert open_direct_peer_exchange(db, "chat-1", "plain human text", None) is None
        exchange = open_direct_peer_exchange(db, "chat-1", "Message from 🤖 Maia (@hermes): status?", author)
        exchange.settle({"final_response": "green", "messages": []})
        counterpart = identity.inbound(author, None, [])
        assert _messages(tmp_path, counterpart.thread_id) == [("message", "status?", "answered"),
                                                              ("reply", "green", "answered")]
        assert ledger.anchored_exchanges(tmp_path, ["chat-1"]) == []
    finally:
        db.close()
