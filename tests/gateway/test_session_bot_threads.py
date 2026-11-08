import json
import sqlite3
import textwrap
from pathlib import Path
from types import SimpleNamespace

import pytest
import pytest_asyncio

from tools import bot_mode_probe

def _profile(root: Path, name: str, display_name: str) -> Path:
    home = root / "profiles" / name
    home.mkdir(parents=True)
    (home / "profile.yaml").write_text(textwrap.dedent(f"""\
        display_name: {display_name}
        ui_meta:
          hermes-bots:
            shape: cloud
        """), encoding="utf-8")
    return home


class _Agent:
    def __init__(self, home: Path, session_id: str):
        self._session_db = SimpleNamespace(db_path=str(home / "state.db"), get_session_title=lambda _sid: "Bot Chat")
        self.session_id = session_id
        self._session_title_hint = None
        self._bot_mode_protocol = True


async def _bot(home: Path, replies: dict, monkeypatch):
    from gateway.config import GatewayConfig
    from gateway.session import SessionStore
    from gateway.session_authority import initialize_session_authority
    from gateway.session_contract import Principal
    from gateway.session_controls import AuthorityConnection
    from gateway.session_local import create_local_session
    from gateway.session_local_title import title_new_session
    from hermes_state import SessionDB

    store = SessionStore(home / "sessions", GatewayConfig())
    store._db = SessionDB(db_path=home / "state.db")
    runner = SimpleNamespace(session_store=store, _session_db=store._db, adapters={}, _draining=False,
                             _evict_cached_agent=lambda route: None)
    runner._adapter_for_source = lambda source: runner.adapters.get(source.platform)
    authority = await initialize_session_authority(runner, profile_id=str(home), instance_id=f"i-{home.name}")
    reader = AuthorityConnection(authority, object(), {"user_id": "uid:1000"})
    owner = Principal(reader.actor.subject, str(home), frozenset({"session:create", "session:read", "session:submit"}),
                      "native")
    chat = create_local_session(authority, owner, {"request_id": "bot", "source": "gui", "cwd": str(home),
                                                    "model": "fixture", "toolsets": []})
    title_new_session(authority, chat, "Bot Chat")
    replies[str(home.resolve())] = []
    return SimpleNamespace(home=home, authority=authority, db=store._db, chat=chat.session_id, reader=reader,
                           sender=SimpleNamespace(authority=authority, actor=owner), replies=replies[str(home.resolve())])


@pytest_asyncio.fixture
async def pair(tmp_path, monkeypatch):
    root = tmp_path / ".hermes"
    root.mkdir()
    alpha_home, beta_home = _profile(root, "alpha", "Alpha"), _profile(root, "beta", "Beta")
    monkeypatch.setenv("HERMES_HOME", str(root))
    from gateway import run
    monkeypatch.setattr(run, "_load_gateway_config", lambda: {"platform_toolsets": {"cli": []}})
    bot_mode_probe._reset_cache_for_tests()
    replies: dict = {}

    async def execute(authority, ref, row):
        db = authority.db
        db.append_message(ref.session_id, "user", content=row["payload"]["text"],
                          platform_message_id=row["request_id"], display_kind="internal_notification")
        reply = replies[str(Path(db.db_path).resolve().parent)].pop(0)
        db.append_message(ref.session_id, "assistant", content=reply)
        return reply

    monkeypatch.setattr("gateway.session_finite.execute_finite_admission", execute)
    alpha, beta = await _bot(alpha_home, replies, monkeypatch), await _bot(beta_home, replies, monkeypatch)
    try:
        yield SimpleNamespace(alpha=alpha, beta=beta)
    finally:
        alpha.db.close()
        beta.db.close()
        bot_mode_probe._reset_cache_for_tests()


async def _send(sender, recipient, body, monkeypatch, *, process_id):
    import asyncio

    from gateway.session_bot import deliver
    from tools import bot_live_delivery as live
    from tools import bot_mode_dm
    import tools.terminal_tool as terminal

    loop = asyncio.get_running_loop()
    delivered = {}

    def authority_delivery(home, params):
        delivered.update(params)
        connection = recipient.sender
        future = asyncio.run_coroutine_threadsafe(deliver(connection, dict(params)), loop)
        return future.result(timeout=20)

    monkeypatch.setattr(live, "find_canonical_live_owner", lambda home: dict(
        profile_home=str(Path(home).resolve()), session_id=recipient.chat, canonical=True,
        lease_id="authority", live_session_id=recipient.chat))
    monkeypatch.setattr(live, "authority_delivery", authority_delivery)
    monkeypatch.setattr(terminal, "terminal_tool", lambda command, **kw: json.dumps(
        {"output": "started", "session_id": process_id}))
    monkeypatch.setattr(bot_mode_dm, "_dm_dir", lambda: sender.home)
    call_id = f"call_{process_id}"
    sender.db.append_message(sender.chat, "assistant", content="", tool_calls=[{
        "id": call_id, "type": "function",
        "function": {"name": "message_agent", "arguments": json.dumps({"target": recipient.home.name, "message": body})}}])
    ack = await asyncio.to_thread(bot_mode_dm.message_agent_tool, recipient.home.name, body,
                                  agent=_Agent(sender.home, sender.chat))
    sender.db.append_message(sender.chat, "tool", content=ack, tool_call_id=call_id, tool_name="message_agent")
    from tests.waiting import async_wait_until
    from tools.bot_live_delivery import read_delivery_result
    delivery_id = json.loads(ack)["delivery_id"]
    await async_wait_until(lambda: (read_delivery_result(recipient.home, delivery_id) or {}).get("status") == "settled",
                           timeout=10, what="the recipient to settle the DM")
    monkeypatch.setattr(bot_mode_dm, "_LIVE_WAIT_SECONDS", 0.05)
    import contextlib
    import io
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        await asyncio.to_thread(bot_mode_dm._wait_live_dm, str(recipient.home), delivery_id, ledger_home=sender.home)
    from tools.process_registry_notifications import format_process_notification
    sender.db.append_message(sender.chat, "user", display_kind="process_complete", content=format_process_notification(
        {"type": "completion", "session_id": process_id, "command": "runner", "exit_code": 0, "output": out.getvalue()}))
    return json.loads(ack), delivered, out.getvalue()


async def _call(bot, method, **params):
    reply = await bot.reader.dispatch({"id": 1, "method": method, "params": params})
    assert "result" in reply, reply
    return reply["result"]


@pytest.mark.asyncio
async def test_both_directions_read_whole_from_each_side_with_links_that_survive_compression(pair, monkeypatch):
    alpha, beta = pair.alpha, pair.beta
    beta.replies.append("Revenue is up 4%.")
    ack, delivered, completion = await _send(alpha, beta, "How did Q3 go?", monkeypatch, process_id="proc_a1")
    assert delivered["message"] == "Message from 🤖 Alpha (@alpha): How did Q3 go?"
    assert set(ack) == {"status", "delivery_id", "to", "detail", "process_id", "reply_delivery"}
    assert json.loads(completion) == {"reply": "Revenue is up 4%.", "status": "settled", "delivery_id": ack["delivery_id"]}
    alpha.replies.append("Thanks, noted.")
    await _send(beta, alpha, "Sharing the deck next.", monkeypatch, process_id="proc_b1")

    from gateway.session_bot import deliver
    await deliver(beta.sender, dict(delivered))

    [alpha_thread] = (await _call(alpha, "bot.thread.list"))["threads"]
    alpha_read = await _call(alpha, "bot.thread.read", thread_id=alpha_thread["thread_id"])
    expected = [("local:alpha", "How did Q3 go?"), ("local:beta", "Revenue is up 4%."),
                ("local:beta", "Sharing the deck next."), ("local:alpha", "Thanks, noted.")]
    assert [(m["sender_key"], m["text"]) for m in alpha_read["messages"]] == expected
    assert [m["status"] for m in alpha_read["messages"]] == ["answered"] * 4
    assert alpha_read["read_only"] is True and alpha_read["coverage"] == "both_sides"
    names = {p["key"]: (p["display_name"], p["is_self"], p["avatar"]["ui_meta"]) for p in alpha_read["participants"]}
    assert names == {"local:alpha": ("Alpha", True, {"shape": "cloud"}), "local:beta": ("Beta", False, {"shape": "cloud"})}
    assert alpha_thread["counterpart"]["display_name"] == "Beta" and alpha_thread["message_count"] == 4

    [beta_thread] = (await _call(beta, "bot.thread.list"))["threads"]
    beta_read = await _call(beta, "bot.thread.read", thread_id=beta_thread["thread_id"])
    assert [(m["sender_key"], m["text"]) for m in beta_read["messages"]] == expected

    links = await _call(alpha, "bot.thread.links", session_id=alpha.chat)
    [link] = links["links"]
    assert (link["kind"], link["count"], link["thread_id"]) == ("messaged", 4, alpha_thread["thread_id"])
    focused = await _call(alpha, "bot.thread.read", thread_id=link["thread_id"], focus=link["exchange_id"])
    assert focused["messages"][focused["focus_index"]]["text"] == "How did Q3 go?"
    rows = {row["message_uid"]: row for row in _rows(alpha.db, alpha.chat)}
    assert rows[link["anchor_uid"]]["role"] == "tool"
    covered = [rows[uid] for uid in link["covered_uids"]]
    assert {row["role"] for row in covered} == {"tool", "user", "assistant"}
    assert not any(row["role"] == "user" and not row["display_kind"] for row in covered)

    since = await _call(alpha, "bot.thread.read", thread_id=link["thread_id"], since_rev=alpha_read["rev"])
    assert since["messages"] == []
    child = _compress(alpha.db, alpha.chat)
    assert alpha.db.get_compression_tip(alpha.chat) == child
    after = await _call(alpha, "bot.thread.links", session_id=alpha.chat)
    assert [(lk["anchor_uid"], sorted(lk["covered_uids"])) for lk in after["links"]] == [
        (link["anchor_uid"], sorted(link["covered_uids"]))]



@pytest.mark.asyncio
async def test_a_human_turn_between_exchanges_keeps_two_entry_rows(pair, monkeypatch):
    alpha, beta = pair.alpha, pair.beta
    beta.replies.append("one")
    await _send(alpha, beta, "first", monkeypatch, process_id="proc_h1")
    alpha.db.append_message(alpha.chat, "user", content="what did beta say?")
    beta.replies.append("two")
    await _send(alpha, beta, "second", monkeypatch, process_id="proc_h2")
    links = (await _call(alpha, "bot.thread.links", session_id=alpha.chat))["links"]
    assert [(lk["kind"], lk["count"]) for lk in links] == [("messaged", 2), ("messaged", 2)]


@pytest.mark.asyncio
async def test_reads_are_profile_scoped_and_authorized(pair, monkeypatch):
    alpha, beta = pair.alpha, pair.beta
    beta.replies.append("ok")
    await _send(alpha, beta, "hi", monkeypatch, process_id="proc_s1")
    [thread] = (await _call(alpha, "bot.thread.list"))["threads"]
    unknown = await alpha.reader.dispatch({"id": 2, "method": "bot.thread.read",
                                           "params": {"thread_id": "bt_" + "0" * 20}})
    assert unknown["error"]["message"] == "not_found"
    mismatch = await alpha.reader.dispatch({"id": 3, "method": "bot.thread.read",
                                            "params": {"thread_id": thread["thread_id"], "profile": "beta"}})
    assert mismatch["error"]["message"] == "profile_mismatch"
    from gateway.session_controls import AuthorityConnection
    blind = AuthorityConnection(alpha.authority, object(), {"user_id": "uid:1000", "capabilities": ["session:submit"]})
    denied = await blind.dispatch({"id": 4, "method": "bot.thread.read", "params": {"thread_id": thread["thread_id"]}})
    assert denied["error"]["message"] == "permission_denied"
    bad = await alpha.reader.dispatch({"id": 5, "method": "bot.thread.read",
                                       "params": {"thread_id": thread["thread_id"], "focus": "out:" + "a" * 64,
                                                  "before": 3}})
    assert bad["error"]["message"] == "invalid_params"
    beta_rows = sqlite3.connect(beta.home / "state.db").execute(
        "SELECT DISTINCT direction FROM bot_thread_events").fetchall()
    alpha_rows = sqlite3.connect(alpha.home / "state.db").execute(
        "SELECT DISTINCT direction FROM bot_thread_events").fetchall()
    assert (alpha_rows, beta_rows) == ([("out",)], [("in",)])
    root_db = alpha.home.parent.parent / "state.db"
    assert not root_db.exists() or not sqlite3.connect(root_db).execute(
        "SELECT name FROM sqlite_master WHERE name = 'bot_thread_events'").fetchall()
    wire = json.dumps(await _call(alpha, "bot.thread.read", thread_id=thread["thread_id"]))
    for leak in ("counterpart_json", "anchor_session_id", "delivery_id", str(alpha.home)):
        assert leak not in wire


def _rows(db, session_id):
    conn = sqlite3.connect(db.db_path)
    conn.row_factory = sqlite3.Row
    try:
        return [dict(row) for row in conn.execute(
            "SELECT id, role, content, display_kind, message_uid FROM messages WHERE session_id = ? ORDER BY id",
            (session_id,))]
    finally:
        conn.close()


def _compress(db, session_id):
    child = session_id + "-c1"
    db.create_session(child, source="cli", parent_session_id=session_id)
    ids = [row["id"] for row in _rows(db, session_id)]
    db._execute_write(lambda conn: db._clone_message_rows(conn, ids, session_id=child))
    db._execute_write(lambda conn: conn.execute("UPDATE messages SET active = 0 WHERE session_id = ?", (session_id,)))
    db._execute_write(lambda conn: conn.execute("UPDATE sessions SET end_reason = 'compression' WHERE id = ?",
                                                (session_id,)))
    return child
