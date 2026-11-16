"""Dashboard force-complete passes the same outcome gate as every other route."""
from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from hermes_cli import kanban_db as kb
from hermes_cli import kanban_db_workspace as kbw
from tests.hermes_cli.kanban_outcome_support import BOARD, PROFILE, REPO, add, claim, event_kinds, merged_payload

pytest_plugins = ["tests.hermes_cli.kanban_outcome_support"]


def _load_plugin():
    plugin_file = Path(__file__).resolve().parents[2] / "plugins" / "kanban" / "dashboard" / "plugin_api.py"
    spec = importlib.util.spec_from_file_location("hermes_kanban_plugin_outcome_force_test", plugin_file)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


@pytest.fixture
def plugin():
    return _load_plugin()


@pytest.fixture
def client(plugin, coord_env):
    app = FastAPI()
    app.include_router(plugin.router, prefix="/api/plugins/kanban")
    return TestClient(app, raise_server_exceptions=False)


def _seeded(conn):
    parent = kb.create_task(conn, title="g", assignee=PROFILE, outcome_contract={"kind": "merged_pr", "repo": REPO})
    child = kb.create_task(conn, title="child", assignee=PROFILE, parents=(parent,))
    run_id = claim(conn, parent)
    workspace = kbw.resolve_workspace(kb.get_task(conn, parent), board=BOARD)
    kbw.set_workspace_path(conn, parent, str(workspace))
    return parent, child, run_id, workspace


def test_status_handler_done_forces_but_cannot_skip_evidence(plugin, conn, hooks):
    parent, child, _run_id, workspace = _seeded(conn)

    class Payload:
        result, summary, metadata = "forced", "forced", None

    with pytest.raises(ValueError, match="outcome refused"):
        plugin._STATUS_HANDLERS["done"](conn, parent, Payload())
    assert kb.get_task(conn, parent).status == "running" and kb.get_task(conn, child).status == "todo"
    assert workspace.exists() and ("kanban_task_completed", parent) not in hooks
    assert "outcome_refused" in event_kinds(conn, parent)
    assert conn.execute("SELECT COUNT(*) FROM task_evidence").fetchone()[0] == 0


def test_patch_route_refuses_then_accepts_verified_force(client, conn, fake_github, hooks):
    parent, child, run_id, workspace = _seeded(conn)
    refused = client.patch(f"/api/plugins/kanban/tasks/{parent}?board={BOARD}",
                           json={"status": "done", "result": "forced", "summary": "forced"})
    assert refused.status_code == 400 and "outcome refused" in refused.json()["detail"]
    assert kb.get_task(conn, parent).status == "running" and kb.get_task(conn, child).status == "todo"
    assert workspace.exists()
    add(conn, parent, run_id, "pr_merged", merged_payload())
    accepted = client.patch(f"/api/plugins/kanban/tasks/{parent}?board={BOARD}",
                            json={"status": "done", "result": "forced", "summary": "forced"})
    assert accepted.status_code == 200, accepted.text
    assert kb.get_task(conn, parent).status == "done" and kb.get_task(conn, child).status == "ready"
    assert hooks.count(("kanban_task_completed", parent)) == 1
