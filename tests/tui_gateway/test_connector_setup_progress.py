import json
import sqlite3

import pytest

from gateway import connector_setup_progress as progress
from tui_gateway import server
from tui_gateway.ws_legacy_fallback import _connection_profile_home

GET = "connectors.setup.progress.get"
SET = "connectors.setup.progress.set"


@pytest.fixture
def root(tmp_path, monkeypatch):
    root = tmp_path / "hermes_home"
    for name in ("work", "home"):
        (root / "profiles" / name).mkdir(parents=True)
    monkeypatch.setenv("HERMES_HOME", str(root))
    return root


def _call(method, profile="work", **params):
    return server._methods[method](1, {"profile": profile, **params})


def _ok(method, profile="work", **params):
    response = _call(method, profile, **params)
    assert "error" not in response, response
    return response["result"]


def _save(connector="google-workspace", step="client", completed=("console",), device="mac", **extra):
    return _ok(SET, connector=connector, step_id=step, completed=list(completed), device=device, **extra)


def test_progress_round_trips_for_every_profile_on_the_install(root):
    saved = _save()["record"]
    assert (saved["connector"], saved["bot"], saved["step_id"], saved["completed"], saved["device"]) == (
        "google-workspace", None, "client", ["console"], "mac")
    for profile in ("work", "home"):
        records = _ok(GET, profile)["records"]
        assert [(r["connector"], r["step_id"], r["completed"], r["device"]) for r in records] == [
            ("google-workspace", "client", ["console"], "mac")]


def test_set_replaces_the_step_and_dedupes_completed_ids(root):
    _save(step="console", completed=[])
    _save(step="client", completed=["console", "apis", "console"], device="iphone")
    [record] = _ok(GET)["records"]
    assert (record["step_id"], record["completed"], record["device"]) == ("client", ["apis", "console"], "iphone")


def test_progress_is_kept_per_bot_where_the_setup_is_per_bot(root):
    _save(connector="slack", step="token", completed=["app"], bot="alpha")
    _save(connector="slack", step="app", completed=[], bot="beta")
    assert {(r["bot"], r["step_id"]) for r in _ok(GET, connector="slack")["records"]} == {("alpha", "token"), ("beta", "app")}
    [only] = _ok(GET, connector="slack", bot="alpha")["records"]
    assert only["completed"] == ["app"]


def test_get_lists_newest_first_and_narrows_by_connector(root, monkeypatch):
    ticks = iter([100.0, 200.0])
    monkeypatch.setattr(progress.time, "time", lambda: next(ticks))
    _save(connector="figma", step="app", completed=[])
    _save(connector="github", step="token", completed=[])
    assert [r["connector"] for r in _ok(GET)["records"]] == ["github", "figma"]
    assert [r["connector"] for r in _ok(GET, connector="figma")["records"]] == ["figma"]


def test_finished_removes_the_record(root):
    _save()
    assert _ok(SET, connector="google-workspace", step_id="done", completed=[], device="mac", finished=True) == {"record": None}
    assert _ok(GET)["records"] == []


@pytest.mark.parametrize("field,value", [
    ("connector", "has space"),
    ("connector", "../etc"),
    ("step_id", "GOCSPX-" + "a" * 80),
    ("step_id", "client secret"),
    ("bot", "bad/bot"),
    ("completed", ["ok", "not ok"]),
    ("completed", [f"s{i}" for i in range(progress.MAX_COMPLETED + 1)]),
    ("device", "toaster"),
])
def test_anything_that_is_not_a_short_id_is_refused_and_nothing_is_written(root, field, value):
    params = {"connector": "google-workspace", "step_id": "client", "completed": [], "device": "mac", field: value}
    response = _call(SET, **params)
    assert response["error"]["code"] == 4000
    assert _ok(GET)["records"] == []


def test_only_the_owner_writes_and_a_guest_reads_nothing(root):
    _save()
    token = _connection_profile_home.set(str(root / "profiles" / "home"))
    try:
        refused = _call(SET, connector="figma", step_id="app", completed=[], device="mac")
        assert refused["error"]["data"]["reason"] == "NOT_OWNER"
        assert _ok(GET)["records"] == []
    finally:
        _connection_profile_home.reset(token)
    assert [r["connector"] for r in _ok(GET)["records"]] == ["google-workspace"]


def test_a_corrupt_completed_column_reads_as_no_steps_done(root):
    _save()
    conn = sqlite3.connect(next(root.rglob(progress.DB_NAME)))
    conn.execute("UPDATE progress SET completed = 'not json'")
    conn.commit()
    conn.close()
    assert _ok(GET)["records"][0]["completed"] == []


def test_the_file_holds_ids_and_no_secret(root):
    _save(completed=["console", "apis"])
    path = next(root.rglob(progress.DB_NAME))
    dump = "\n".join(sqlite3.connect(path).iterdump())
    assert json.dumps(["apis", "console"]) in dump
    assert path.stat().st_mode & 0o077 == 0
