import textwrap
from types import SimpleNamespace

import pytest

import hermes_cli.config as hc
import tui_gateway.server as srv


@pytest.fixture
def home(tmp_path, monkeypatch):
    path = tmp_path / "hermes"
    path.mkdir()
    (path / "profile.yaml").write_text(
        textwrap.dedent("""\
            ui_meta:
              hermes-bots:
                shape: cloud
        """), encoding="utf-8")
    (path / "config.yaml").write_text("approvals:\n  mode: manual\n", encoding="utf-8")
    monkeypatch.setenv("HERMES_HOME", str(path))
    hc._LOAD_CONFIG_CACHE.clear()
    yield path
    hc._LOAD_CONFIG_CACHE.clear()
    srv._sessions.pop("ui-bot", None)


def _session(title):
    session = {"session_key": "bot-key", "history": [], "pending_title": title,
               "agent": SimpleNamespace(_session_title_hint=title)}
    srv._sessions["ui-bot"] = session
    return session


def _rpc(method, **params):
    return srv.handle_request({"id": "r", "method": method, "params": {"session_id": "ui-bot", **params}})


def test_old_held_files_on_disk_are_not_listed_as_approvals(home):
    _session("Bot Chat")
    pending = home / "bot_mode" / "drafts" / "pending"
    pending.mkdir(parents=True)
    (pending / ("a" * 32 + ".json")).write_text(
        '{"id": "%s", "state": "pending", "tool": "connectors__gmail__SEND_EMAIL", "args": {"body": "hi"}}' % ("a" * 32),
        encoding="utf-8")
    assert _rpc("approval.pending")["result"] == {"approvals": []}


def test_resolve_all_with_an_edit_and_no_request_id_is_refused(home):
    _session("Bot Chat")
    reply = _rpc("approval.respond", choice="once", all=True, edited_text="HIJACK")
    assert reply["error"]["code"] == 4135
