import json
import logging
import subprocess
import sys
import threading
from contextlib import contextmanager
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock

import pytest

import hermes_cli.config as hc
import hermes_yaml as yaml
from agent.delegation_context import delegated_child_context
from gateway.session_context import clear_session_vars, set_session_vars
from gateway.session_ingress import viewer_turn
from gateway.session_operator import is_viewer_input
from hermes_cli.profile_admin_guard import CREATE_REFUSED_MESSAGE
from tools import approval
from tools.code_execution_tool import execute_code
from tools.skill_provenance import BACKGROUND_REVIEW, reset_current_write_origin, set_current_write_origin
from tools.terminal_tool import cleanup_all_environments, terminal_tool

REPO_ROOT = Path(__file__).resolve().parents[2]
SESSION = "owner-create-session"
TYPED_ROW = {"request_id": "typed-1", "payload": {"text": "make me a bot"}}
PRODUCER_ROW = {"request_id": "bot:abc", "payload": {"text": "make a bot", "local_automation_v1": {}}}


@pytest.fixture
def world(tmp_path, monkeypatch):
    home = tmp_path / "home"
    root = home / ".hermes"
    root.mkdir(parents=True)
    (root / "config.yaml").write_text('model:\n  default: test-model\napprovals:\n  mode: "off"\n', encoding="utf-8")
    shim = tmp_path / "bin" / "hermes"
    shim.parent.mkdir()
    shim.write_text(f'#!/bin/sh\nPYTHONPATH={REPO_ROOT} exec {sys.executable} -m hermes_cli.main "$@"\n',
                    encoding="utf-8")
    shim.chmod(0o755)
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setenv("HERMES_HOME", str(root))
    monkeypatch.setenv("HERMES_STATE_DB_GUARD_BYPASS", "1")
    for var in ("HERMES_CRON_SESSION", "HERMES_SINGLE_QUERY_SESSION", "HERMES_TUI_GATEWAY_URL"):
        monkeypatch.delenv(var, raising=False)
    monkeypatch.chdir(tmp_path)
    hc._LOAD_CONFIG_CACHE.clear()
    yield SimpleNamespace(root=root, hermes=str(shim), profile=root / "profiles" / "scout")
    cleanup_all_environments()
    hc._LOAD_CONFIG_CACHE.clear()


@contextmanager
def turn(row=TYPED_ROW, *, capabilities=("session:approve",), **session):
    live = SimpleNamespace(event_stream=SimpleNamespace(lock=threading.RLock()),
                           subscribers={"app": SimpleNamespace(capabilities=set(capabilities))})
    viewer = viewer_turn.set(live if is_viewer_input(row) else None)
    variables = set_session_vars(**{"platform": "local", "source": "ios", "session_key": SESSION,
                                    "session_id": SESSION, **session})
    notify = MagicMock()
    approval.register_gateway_notify(SESSION, notify)
    try:
        yield notify
    finally:
        approval.unregister_gateway_notify(SESSION)
        clear_session_vars(variables)
        viewer_turn.reset(viewer)


@contextmanager
def background_review():
    token = set_current_write_origin(BACKGROUND_REVIEW)
    try:
        with turn():
            yield
    finally:
        reset_current_write_origin(token)


@contextmanager
def delegated_child():
    with turn(), delegated_child_context():
        yield


REFUSED_CONTEXTS = {
    "cron": lambda: turn(cron_session="1"),
    "webhook": lambda: turn(platform="webhook"),
    "single-query": lambda: turn(),
    "relayed-bot-message": lambda: turn(PRODUCER_ROW),
    "plugin-injection": lambda: turn({"request_id": "plugin-1", "payload": PRODUCER_ROW["payload"]}),
    "hosted-room-task": lambda: turn({"request_id": "hosted:1", "payload": {"text": "make a bot"}}),
    "delegated-child": delegated_child,
    "background-review": background_review,
    "no-approver-attached": lambda: turn(capabilities=("session:read",)),
}


def _shell(world, command):
    return json.loads(terminal_tool(command, task_id="owner-create"))


def _script(world, name):
    code = (f"import subprocess\n"
            f"done = subprocess.run(['{world.hermes}', 'profile', 'create', '{name}'], capture_output=True, text=True)\n"
            f"print(done.returncode, done.stderr[-2000:])\n")
    return json.loads(execute_code(code, task_id="owner-create", enabled_tools=["terminal"]))


def _yaml(path):
    return yaml.safe_load(path.read_text(encoding="utf-8"))


def _assert_form_state(world):
    from tools.bot_mode_probe import _is_bot_managed
    from tui_gateway import server

    assert _yaml(world.profile / "config.yaml")["approvals"]["mode"] == "off"
    meta = _yaml(world.profile / "profile.yaml")
    assert meta["ui_meta"]["hermes-bots"]["title"] == "scout"
    assert isinstance(meta["ui_meta"]["hermes-bots"]["created"], int)
    assert meta["_ui_meta_revisions"]["hermes-bots"] == 1
    assert (world.profile / "SOUL.md").read_text(encoding="utf-8").startswith("# scout\n\nYou are scout,")
    assert _is_bot_managed(world.profile)
    listed = server._methods["profiles.list"](1, {"include_sessions": False})["result"]["profiles"]
    row = next(r for r in listed if r["name"] == "scout")
    assert row["onboarding_pending"] is True and row["ui_meta"]["hermes-bots"]["title"] == "scout"
    described = server._methods["profiles.describe"](2, {"name": "scout"})["result"]
    assert described["model"]["default"] == "test-model"


@pytest.mark.parametrize("create", [
    lambda world: _shell(world, f"{world.hermes} profile create scout"),
    lambda world: _script(world, "scout"),
], ids=["shell", "script"])
def test_the_owners_typed_turn_creates_the_forms_bot_with_no_card(world, caplog, create):
    caplog.set_level(logging.INFO, logger="tools.approval")
    with turn() as notify:
        result = create(world)
        notify.assert_not_called()
        assert approval.list_gateway_approvals(SESSION) == []
    assert world.profile.is_dir(), result
    _assert_form_state(world)
    logged = [r.getMessage() for r in caplog.records if r.name == "tools.approval"]
    assert logged == ["bot creation approved by the owner turn"]


@pytest.mark.parametrize("context", list(REFUSED_CONTEXTS))
def test_any_other_context_is_refused_and_creates_nothing(world, monkeypatch, context):
    if context == "single-query":
        monkeypatch.setenv("HERMES_SINGLE_QUERY_SESSION", "1")
    with REFUSED_CONTEXTS[context]():
        shell = _shell(world, f"{world.hermes} profile create scout")
        script = _script(world, "scout")
    assert shell["status"] == "blocked" and shell["error"] == CREATE_REFUSED_MESSAGE, shell
    assert CREATE_REFUSED_MESSAGE in json.dumps(script), script
    assert not world.profile.exists()


def test_the_owners_explicit_clone_flags_are_kept(world):
    (world.root / "SOUL.md").write_text("main soul\n", encoding="utf-8")
    with turn():
        result = _shell(world, f"{world.hermes} profile create scout --no-skills")
    assert world.profile.is_dir(), result
    assert (world.profile / ".no-bundled-skills").is_file()
    assert "approvals" not in (_yaml(world.profile / "config.yaml") or {})
    assert _yaml(world.profile / "profile.yaml")["ui_meta"]["hermes-bots"]["title"] == "scout"


def test_bot_create_in_the_owners_turn_marks_the_bot_for_the_app(world):
    with turn():
        result = _shell(world, f"{world.hermes} bot create scout --display-name Scout")
    assert world.profile.is_dir(), result
    assert _yaml(world.profile / "profile.yaml")["ui_meta"]["hermes-bots"]["title"] == "Scout"


def test_a_create_from_the_owners_own_terminal_is_unchanged(world):
    done = subprocess.run([world.hermes, "profile", "create", "scout", "--no-alias", "--no-skills"],
                          capture_output=True, text=True, timeout=200, check=False)
    assert done.returncode == 0, done.stderr
    meta = world.profile / "profile.yaml"
    assert not meta.is_file() or "ui_meta" not in _yaml(meta)
