from __future__ import annotations

import importlib.util
import json
import subprocess
import threading
from pathlib import Path
from types import SimpleNamespace

import pytest

from gateway import kanban_watchers_dispatcher as kwd
from hermes_cli import kanban as kanban_cli
from hermes_cli import kanban_db as kb
from hermes_cli import kanban_db_connect as kbc
from hermes_cli import kanban_db_dispatch as kbd
from hermes_cli import kanban_decompose, kanban_specify
from hermes_cli.kanban_board_mode import ExternalBoardError, board_dispatch_mode


@pytest.fixture
def home(tmp_path, monkeypatch):
    root = tmp_path / ".hermes"
    root.mkdir()
    monkeypatch.setenv("HERMES_HOME", str(root))
    monkeypatch.setenv("HERMES_KANBAN_HOME", str(root))
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    kb.init_db()
    return root


@pytest.fixture
def spawns(monkeypatch):
    calls: list = []

    def recording(task, workspace, board=None):
        calls.append(task.id)

    def no_popen(*args, **kwargs):
        calls.append("popen")
        raise AssertionError("a worker process must not start")

    monkeypatch.setattr(kbd, "_default_spawn", recording)
    monkeypatch.setattr(subprocess, "Popen", no_popen)
    return calls


def _seed(slug: str) -> dict:
    kb.create_board(slug)
    with kbc.connect(board=slug) as conn:
        ready = kb.create_task(conn, title="ready", assignee="default")
        unassigned = kb.create_task(conn, title="unassigned")
        review = kb.create_task(conn, title="review", assignee="default")
        conn.execute("UPDATE tasks SET status='review' WHERE id=?", (review,))
        conn.commit()
    return {"ready": ready, "unassigned": unassigned, "review": review}


def _external(slug: str) -> None:
    kb.write_board_metadata(slug, dispatch_mode="external")


def _tick(slug: str, **kwargs):
    with kbc.connect(board=slug) as conn:
        return kbd.dispatch_once(conn, board=slug, **kwargs)


def test_default_board_spawns_but_external_board_does_not(home, spawns):
    _seed("plain")
    _seed("coord")
    _external("coord")

    plain = _tick("plain", default_assignee="default")
    assert plain.spawned and spawns

    spawns.clear()
    result = _tick("coord", default_assignee="default")
    assert result.spawned == []
    assert result.auto_assigned_default == []
    assert spawns == []
    with kbc.connect(board="coord") as conn:
        assert {t.status for t in kb.list_tasks(conn)} == {"ready", "review"}
        assert [t.assignee for t in kb.list_tasks(conn) if t.title == "unassigned"] == [None]


def test_dispatch_mode_persists_across_reload(home):
    kb.create_board("coord", dispatch_mode="external")
    assert board_dispatch_mode("coord") == "external"
    on_disk = json.loads(kb.board_metadata_path("coord").read_text())
    assert on_disk["dispatch_mode"] == "external"
    kb.write_board_metadata("coord", name="Renamed")
    assert board_dispatch_mode("coord") == "external"
    kb.write_board_metadata("coord", dispatch_mode="workers")
    assert board_dispatch_mode("coord") == "workers"


def test_external_board_still_promotes_and_reclaims(home, spawns):
    kb.create_board("coord", dispatch_mode="external")
    with kbc.connect(board="coord") as conn:
        parent = kb.create_task(conn, title="parent", assignee="p")
        child = kb.create_task(conn, title="child", assignee="p", parents=[parent])
        conn.execute("UPDATE tasks SET status='done' WHERE id=?", (parent,))
        conn.commit()
    result = _tick("coord")
    assert result.promoted == 1
    with kbc.connect(board="coord") as conn:
        assert kb.get_task(conn, child).status == "ready"
    assert spawns == []


def test_external_board_does_not_stop_other_board(home, spawns):
    _seed("coord")
    _seed("other")
    _external("coord")
    assert _tick("coord").spawned == []
    assert _tick("other").spawned


def test_cli_dispatch_spawns_nothing_on_external_board(home, spawns):
    _seed("coord")
    _external("coord")
    kb.set_current_board("coord")
    out = kanban_cli.run_slash("dispatch --json")
    assert json.loads(out)["spawned"] == []
    assert spawns == []


def test_run_daemon_tick_spawns_nothing_on_external_board(home, spawns):
    _seed("coord")
    _external("coord")
    kb.set_current_board("coord")
    stop = threading.Event()
    ticks: list = []
    kbd.run_daemon(interval=0.01, stop_event=stop, on_tick=lambda res: (ticks.append(res), stop.set()))
    assert len(ticks) == 1 and ticks[0].spawned == []
    assert spawns == []


def test_dashboard_dispatch_endpoint_spawns_nothing_on_external_board(home, spawns):
    plugin_file = Path(__file__).resolve().parents[2] / "plugins" / "kanban" / "dashboard" / "plugin_api.py"
    spec = importlib.util.spec_from_file_location("kanban_dashboard_board_mode_test", plugin_file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    _seed("coord")
    _external("coord")
    payload = module.dispatch(dry_run=False, max_n=8, board="coord")
    assert payload["spawned"] == []
    assert spawns == []


def test_gateway_dispatcher_tick_spawns_nothing_on_external_board(home, spawns):
    _seed("coord")
    _seed("plain")
    _external("coord")
    settings = kwd._DispatcherSettings(60.0, None, None, 2, 0, True, "default", None)
    dispatcher = kwd._KanbanDispatcher(kb, settings)
    by_slug = dict(dispatcher.tick_once())
    assert by_slug["coord"].spawned == []
    assert by_slug["plain"].spawned
    assert "popen" not in spawns
    with kbc.connect(board="coord") as conn:
        assert {t.status for t in kb.list_tasks(conn)} == {"ready", "review"}


def _triage(slug: str) -> str:
    with kbc.connect(board=slug) as conn:
        return kb.create_task(conn, title="idea", triage=True)


@pytest.fixture
def aux_calls(monkeypatch):
    calls: list = []

    def boom(*args, **kwargs):
        calls.append(args)
        return None, "aux reached"

    monkeypatch.setattr(kanban_decompose, "_call_aux", boom)
    monkeypatch.setattr(kanban_specify, "_call_aux", boom)
    return calls


def test_decompose_and_specify_refuse_on_external_board(home, aux_calls):
    kb.create_board("coord", dispatch_mode="external")
    task_id = _triage("coord")
    with kb.scoped_current_board("coord"):
        with pytest.raises(ExternalBoardError):
            kanban_decompose.decompose_task(task_id)
        with pytest.raises(ExternalBoardError):
            kanban_specify.specify_task(task_id)
    assert aux_calls == []


def test_decompose_and_specify_still_reach_aux_on_ordinary_board(home, aux_calls):
    kb.create_board("plain")
    task_id = _triage("plain")
    with kb.scoped_current_board("plain"):
        assert not kanban_decompose.decompose_task(task_id).ok
        assert not kanban_specify.specify_task(task_id).ok
    assert len(aux_calls) == 2


def test_cli_decompose_reports_external_board_without_aux(home, aux_calls):
    kb.create_board("coord", dispatch_mode="external")
    task_id = _triage("coord")
    kb.set_current_board("coord")
    out = kanban_cli.run_slash(f"decompose {task_id}")
    assert "coordinator-owned" in out
    assert aux_calls == []


def test_gateway_auto_decompose_tick_skips_external_board(home, aux_calls):
    kb.create_board("coord", dispatch_mode="external")
    _triage("coord")
    settings = kwd._DispatcherSettings(60.0, None, None, 2, 0, True, None, None)
    dispatcher = kwd._KanbanDispatcher(kb, settings)
    assert dispatcher.auto_decompose_tick(5) == 0
    assert aux_calls == []


def test_boards_cli_dispatch_mode_round_trip(home):
    out = kanban_cli.run_slash("boards create coord --dispatch-mode external")
    assert "coord" in out
    assert board_dispatch_mode("coord") == "external"
    kanban_cli.run_slash("boards set-dispatch-mode coord workers")
    assert board_dispatch_mode("coord") == "workers"
    kanban_cli.run_slash("boards set-dispatch-mode coord external")
    assert board_dispatch_mode("coord") == "external"


def test_boards_cli_rejects_invalid_dispatch_mode(home):
    kb.create_board("coord")
    out = kanban_cli.run_slash("boards set-dispatch-mode coord bogus")
    assert "invalid choice" in out or "bogus" in out
    assert board_dispatch_mode("coord") == "workers"
    with pytest.raises(ValueError):
        kb.write_board_metadata("coord", dispatch_mode="bogus")
