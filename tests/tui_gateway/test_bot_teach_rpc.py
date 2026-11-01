"""bot.teach.*: record a demonstration, hand the bot the prompt, review the draft it writes."""

from __future__ import annotations

import json
import textwrap

import pytest

from hermes_cli.config import load_config
from tools.bot_desktop import lease, teach, teach_capture, teach_log
from tools.skill_manager_tool import skill_manage
from tools.skills_tool import find_all_skills

SKILL = textwrap.dedent("""\
    ---
    name: {name}
    description: Download the weekly report from the shop.
    version: 0.1.0
    ---

    # Report Skill

    ## Procedure

    1. Open the shop with `browser_exec`.
    """)


@pytest.fixture
def rpc(monkeypatch, tmp_path):
    from tools.bot_desktop import runtime
    from tui_gateway import server

    lease._reset_for_tests()
    monkeypatch.setattr(teach, "unavailable_reason", lambda: None)
    monkeypatch.setattr(runtime, "rfb_socket_path", lambda: tmp_path / "rfb.sock")

    def call(method, **params):
        return server.handle_request({"jsonrpc": "2.0", "id": 9, "method": method, "params": params})

    yield call
    for recorder in list(teach_capture._recorders.values()):
        recorder.stop()
    teach_capture._recorders.clear()
    lease._reset_for_tests()


def _viewer(rpc, *, holding=True):
    viewer = rpc("display.observe")["result"]["viewer_id"]
    if holding:
        lease.acquire(viewer)
    return viewer


def _record(rpc, events):
    viewer = _viewer(rpc)
    assert rpc("bot.teach.start", viewer_id=viewer)["result"]["recording"] is True
    log = teach_capture.active(teach_log.get_hermes_home()).log
    for event in events:
        log.add(event)
    return viewer


EVENTS = [
    {"kind": "navigate", "url": "https://shop.example.com/login?x=1"},
    {"kind": "type", "target": {"role": "textbox", "name": "Password", "input_type": "password"}, "value": "hunter2"},
    {"kind": "click", "target": {"role": "button", "name": "Sign in"}},
]


def test_status_before_anything_happens(rpc):
    result = rpc("bot.teach.status")["result"]
    assert result["available"] is True and result["recording"] is False and result["pending"] is None
    assert result["max_seconds"] == 600 and result["event_count"] == 0


def test_status_says_why_teaching_is_unavailable(rpc, monkeypatch):
    monkeypatch.setattr(teach, "unavailable_reason", lambda: "sandbox")
    result = rpc("bot.teach.status")["result"]
    assert result["available"] is False and result["reason"] == "sandbox"
    refused = rpc("bot.teach.start", viewer_id=_viewer(rpc))
    assert refused["error"]["data"]["code"] == "unavailable"


def test_unknown_params_are_rejected(rpc):
    assert rpc("bot.teach.status", bogus=1)["error"]["code"] == 4000


def test_only_the_viewer_holding_the_lease_can_start(rpc):
    invented = rpc("bot.teach.start", viewer_id="made-up")
    assert invented["error"]["data"]["code"] == "viewer_mismatch"
    watching = rpc("bot.teach.start", viewer_id=_viewer(rpc, holding=False))
    assert watching["error"]["data"]["code"] == "not_in_control"
    assert teach_capture.active(teach_log.get_hermes_home()) is None
    assert rpc("bot.teach.start")["error"]["data"]["code"] == "not_in_control"


def test_a_second_recording_is_refused_while_one_runs(rpc):
    viewer = _record(rpc, [])
    again = rpc("bot.teach.start", viewer_id=viewer)
    assert again["error"]["data"]["code"] == "recording_in_progress"
    assert rpc("bot.teach.status")["result"]["recording"] is True


def test_stopping_an_empty_recording_leaves_nothing_behind(rpc):
    _record(rpc, [])
    result = rpc("bot.teach.stop")["result"]
    assert result["empty"] is True and not result.get("prompt")
    assert not list(teach_log.teach_root().iterdir())
    assert rpc("bot.teach.status")["result"]["pending"] is None


def test_stop_without_a_recording_is_an_error_with_a_code(rpc):
    assert rpc("bot.teach.stop")["error"]["data"]["code"] == "not_recording"


def test_discarding_while_recording_deletes_the_log(rpc):
    _record(rpc, EVENTS)
    assert rpc("bot.teach.stop", discard=True)["result"]["empty"] is True
    assert not list(teach_log.teach_root().iterdir())
    assert not any(name.startswith("taught-") for name in (load_config().get("skills") or {}).get("disabled", []))


def test_record_stop_review_approve(rpc):
    _record(rpc, EVENTS)
    stopped = rpc("bot.teach.stop")["result"]
    name, teach_id = stopped["skill_name"], stopped["teach_id"]
    assert stopped["empty"] is False and stopped["event_count"] == 3
    assert name in stopped["prompt"] and "hunter2" not in stopped["prompt"]
    assert name in load_config()["skills"]["disabled"]

    status = rpc("bot.teach.status")["result"]
    assert status["recording"] is False and status["pending"]["state"] == "drafting"
    assert rpc("bot.teach.draft", teach_id=teach_id)["result"]["state"] == "drafting"
    assert rpc("bot.teach.prompt", teach_id=teach_id)["result"]["prompt"] == stopped["prompt"]
    blocked = rpc("bot.teach.start", viewer_id=_viewer(rpc))
    assert blocked["error"]["data"]["code"] == "draft_pending"
    assert rpc("bot.teach.approve", teach_id=teach_id, content_hash="x")["error"]["data"]["code"] == "draft_not_ready"

    assert json.loads(skill_manage(action="create", name=name, content=SKILL.format(name=name)))["success"]
    assert name not in {s["name"] for s in find_all_skills()}
    draft = rpc("bot.teach.draft", teach_id=teach_id)["result"]
    assert draft["state"] == "ready" and f"name: {name}" in draft["content"]
    assert rpc("bot.teach.status")["result"]["pending"]["state"] == "ready"

    saved = rpc("bot.teach.draft.save", teach_id=teach_id, content=SKILL.format(name=name).replace("weekly", "monthly"))
    assert "monthly" in saved["result"]["content"] and name not in {s["name"] for s in find_all_skills()}
    invalid = rpc("bot.teach.draft.save", teach_id=teach_id, content="nope")
    assert invalid["error"]["code"] == 5310

    unreviewed = rpc("bot.teach.approve", teach_id=teach_id)
    assert unreviewed["error"]["data"]["code"] == "draft_changed"
    approved = rpc("bot.teach.approve", teach_id=teach_id, content_hash=saved["result"]["content_hash"])["result"]
    assert approved == {"teach_id": teach_id, "skill_name": name, "enabled": True}
    assert name in {s["name"] for s in find_all_skills()}
    assert rpc("bot.teach.status")["result"]["pending"] is None
    assert not (teach_log.teach_root() / teach_id).exists()


def test_record_stop_discard_removes_the_draft(rpc):
    _record(rpc, EVENTS)
    stopped = rpc("bot.teach.stop")["result"]
    name, teach_id = stopped["skill_name"], stopped["teach_id"]
    skill_manage(action="create", name=name, content=SKILL.format(name=name))
    assert rpc("bot.teach.discard", teach_id=teach_id)["result"] == {"teach_id": teach_id, "discarded": True}
    assert name not in {s["name"] for s in find_all_skills(skip_disabled=True)}
    assert name in load_config()["skills"]["disabled"]
    assert rpc("bot.teach.status")["result"]["pending"] is None
    assert rpc("bot.teach.draft", teach_id=teach_id)["error"]["data"]["code"] == "unknown_draft"
    assert rpc("bot.teach.approve", teach_id=teach_id, content_hash="x")["error"]["data"]["code"] == "unknown_draft"


def test_a_recording_that_ended_by_itself_is_collected_by_stop(rpc):
    viewer = _record(rpc, EVENTS)
    lease.release(viewer)
    recorder = teach_capture.active(teach_log.get_hermes_home())
    from tests.waiting import wait_until
    wait_until(lambda: not recorder.snapshot()["recording"], what="recorder noticed the hand back")
    status = rpc("bot.teach.status")["result"]
    assert status["recording"] is False and status["ended"] == "control_returned" and status["event_count"] == 3
    stopped = rpc("bot.teach.stop")["result"]
    assert stopped["empty"] is False and stopped["reason"] == "control_returned"
    assert teach_capture.active(teach_log.get_hermes_home()) is None


def test_a_named_profile_keeps_its_own_recordings_and_skills(rpc, monkeypatch, tmp_path):
    from hermes_constants import get_hermes_home
    from tui_gateway import server

    named = tmp_path / "profiles" / "named"
    named.mkdir(parents=True)
    monkeypatch.setattr(server, "_profile_home", lambda name: str(named) if name == "named" else None)
    viewer = rpc("display.observe", profile="named")["result"]["viewer_id"]
    lease.acquire(viewer, profile_key=str(named))
    assert rpc("bot.teach.start", profile="named", viewer_id=viewer)["result"]["recording"] is True
    assert rpc("bot.teach.status")["result"]["recording"] is False
    teach_capture.active(named).log.add(EVENTS[0])
    stopped = rpc("bot.teach.stop", profile="named")["result"]
    assert (named / "bot-desktop" / "teach" / stopped["teach_id"]).is_dir()
    assert not (get_hermes_home() / "bot-desktop" / "teach").exists()
    assert stopped["skill_name"] in (named / "config.yaml").read_text(encoding="utf-8")
    assert stopped["skill_name"] not in (load_config().get("skills") or {}).get("disabled", [])
    rpc("bot.teach.discard", profile="named", teach_id=stopped["teach_id"])


def test_a_status_poll_alone_deletes_the_recording_once_the_draft_exists(rpc):
    _record(rpc, EVENTS)
    stopped = rpc("bot.teach.stop")["result"]
    log_file = teach_log.teach_root() / stopped["teach_id"] / "events.jsonl"
    assert log_file.exists()
    rpc("bot.teach.status")
    assert log_file.exists()
    skill_manage(action="create", name=stopped["skill_name"], content=SKILL.format(name=stopped["skill_name"]))
    assert rpc("bot.teach.status")["result"]["pending"]["state"] == "ready"
    assert not log_file.exists()


def test_two_stops_at_once_create_one_draft(rpc):
    import threading

    _record(rpc, EVENTS)
    results = []

    def stop():
        results.append(rpc("bot.teach.stop"))

    threads = [threading.Thread(target=stop) for _ in range(4)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    assert sum("result" in r for r in results) == 1
    assert all(r["error"]["data"]["code"] == "not_recording" for r in results if "error" in r)
    assert len([p for p in teach_log.teach_root().iterdir() if (p / "meta.json").exists()]) == 1
