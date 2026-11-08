import asyncio
import json
import subprocess
import sys
import textwrap
from pathlib import Path

import pytest

from hermes_state import SessionDB
from tools import bot_mode_probe
from tools import bot_thread_identity as identity
from tools import bot_thread_ledger as ledger
from tools.bot_thread_ledger import PageRequest

REPO = Path(__file__).resolve().parents[2]
SENT = "a" * 64
RECEIVED = "b" * 64
ORPHAN = "c" * 64


def _profile(root: Path, name: str) -> Path:
    home = root / "profiles" / name
    home.mkdir(parents=True)
    (home / "profile.yaml").write_text(textwrap.dedent(f"""\
        display_name: {name.title()}
        ui_meta:
          hermes-bots:
            shape: cloud
        """), encoding="utf-8")
    return home


def _history(home: Path) -> None:
    db = SessionDB(db_path=home / "state.db")
    try:
        db.create_session("chat", source="cli")
        db.set_session_title("chat", "Bot Chat")
        for target, delivery_id, label, process_id in (("beta", SENT, "@beta", "proc_1"),
                                                       ("ghost", "d" * 64, "@ghost", "proc_2")):
            call = f"call_{process_id}"
            db.append_message("chat", "assistant", content="", timestamp=100.0, tool_calls=[{
                "id": call, "type": "function", "function": {
                    "name": "message_agent", "arguments": json.dumps({"target": target, "message": f"hi {target}"})}}])
            db.append_message("chat", "tool", tool_call_id=call, timestamp=100.0, content=json.dumps({
                "status": "queued", "delivery_id": delivery_id, "to": label, "process_id": process_id}))
        from tools.process_registry_notifications import format_process_notification
        db.append_message("chat", "user", display_kind="process_complete", timestamp=101.0,
                          content=format_process_notification({"type": "completion", "session_id": "proc_1",
                                                               "command": "runner", "exit_code": 0, "output": json.dumps(
                                                                   {"reply": "hey alpha", "status": "settled",
                                                                    "delivery_id": SENT})}))
        db.append_message("chat", "user", content="Message from 🤖 Beta (@beta): ping", timestamp=200.0,
                          platform_message_id=f"bot:{RECEIVED}", display_kind="internal_notification")
    finally:
        db.close()
    mailbox = home / "runtime" / "bot_live_delivery"
    mailbox.mkdir(parents=True)
    for delivery_id, author in ((RECEIVED, {"id": "bot:beta", "name": "beta", "is_bot": True}), (ORPHAN, None)):
        receipt = {"delivery_id": delivery_id, "session_id": "chat", "admission_id": f"adm-{delivery_id[:4]}",
                   "message": "Message from 🤖 Beta (@beta): ping", "status": "settled", "reply": "pong"}
        if author:
            receipt["author"] = author
        (mailbox / f"{delivery_id}.json").write_text(json.dumps(receipt), encoding="utf-8")


@pytest.fixture
def alpha(tmp_path, monkeypatch):
    root = tmp_path / ".hermes"
    alpha_home = _profile(root, "alpha")
    _profile(root, "beta")
    monkeypatch.setenv("HERMES_HOME", str(root))
    bot_mode_probe._reset_cache_for_tests()
    _history(alpha_home)
    yield alpha_home
    bot_mode_probe._reset_cache_for_tests()


def _thread(home):
    beta = identity.outbound_local("beta", "beta", "Beta")
    page = ledger.read_page(home, beta.thread_id, PageRequest(limit=20))
    return [(m.exchange_id[:3], m.part.value, m.body, m.status.value, m.occurred_at) for m in page.messages]


def test_backfill_imports_joined_history_once_and_skips_what_it_cannot_attribute(alpha):
    from gateway.session_bot_threads_backfill import DONE_KEY, backfill
    db = SessionDB(db_path=alpha / "state.db")
    try:
        assert asyncio.run(backfill(alpha, db)) is True
        first = _thread(alpha)
        assert first == [("out", "message", "hi beta", "answered", 100.0), ("out", "reply", "hey alpha", "answered", 100.0),
                         ("in:", "message", "ping", "answered", 200.0), ("in:", "reply", "pong", "answered", 200.0)]
        assert len(ledger.thread_summaries(alpha)) == 1
        assert asyncio.run(backfill(alpha, db)) is False
        db._execute_write(lambda conn: conn.execute("DELETE FROM state_meta WHERE key = ?", (DONE_KEY,)))
        assert asyncio.run(backfill(alpha, db)) is True
        assert _thread(alpha) == first
        page = ledger.read_page(alpha, identity.outbound_local("beta", "beta", "Beta").thread_id, PageRequest(limit=5))
        assert page.history_since == 100.0
    finally:
        db.close()


def test_backfill_never_overwrites_what_the_live_ledger_recorded(alpha):
    from gateway.session_bot_threads_backfill import backfill
    beta = identity.outbound_local("beta", "beta", "Beta")
    key = ledger.ExchangeKey.of(ledger.Direction.outbound, SENT)
    ledger.record_message(alpha, key, beta, "live text", status=ledger.Status.delivered, occurred_at=150.0)
    db = SessionDB(db_path=alpha / "state.db")
    try:
        asyncio.run(backfill(alpha, db))
    finally:
        db.close()
    assert _thread(alpha)[0][:4] == ("out", "message", "live text", "answered")


def test_a_ledger_write_from_another_process_moves_the_change_signal(tmp_path):
    from tui_gateway.change_watcher import _bot_thread_revision
    SessionDB(db_path=tmp_path / "state.db").close()
    before = _bot_thread_revision(tmp_path / "state.db")
    script = ("import sys; from pathlib import Path; from tools import bot_thread_ledger as L, bot_thread_identity as I;"
              "L.record_message(Path(sys.argv[1]), L.ExchangeKey.of(L.Direction.inbound, 'e' * 64),"
              " I.outbound_local('beta', 'beta', 'Beta'), 'x', status=L.Status.delivered)")
    subprocess.run([sys.executable, "-c", script, str(tmp_path)], check=True, cwd=REPO)
    from tests.waiting import wait_until
    wait_until(lambda: _bot_thread_revision(tmp_path / "state.db") == 1, timeout=5, what="the watcher to see the write")
    assert before == 0
