from __future__ import annotations

from pathlib import Path

import pytest

from cron.jobs import load_jobs, use_cron_store
from cron.schedule_describe import CUSTOM_SCHEDULE, describe_schedule
from hermes_cli.profiles import create_profile, get_profile_dir
from tui_gateway import server


@pytest.fixture
def two_bots(tmp_path, monkeypatch) -> Path:
    home = tmp_path / ".hermes"
    home.mkdir()
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    monkeypatch.setenv("HERMES_HOME", str(home))
    monkeypatch.setattr(server, "_hermes_home", home)
    create_profile("scout", no_alias=True, no_skills=True)
    create_profile("pilot", no_alias=True, no_skills=True)
    (get_profile_dir("scout") / "config.yaml").write_text("timezone: Asia/Ho_Chi_Minh\n", encoding="utf-8")
    (get_profile_dir("pilot") / "config.yaml").write_text("timezone: Europe/Paris\n", encoding="utf-8")
    return home


def _cron(action: str, profile: str, **params) -> dict:
    from tui_gateway.contracts import METHODS

    request = {"action": action, "profile": profile, **params}
    METHODS["cron.manage"].params.model_validate(request)
    response = server._methods["cron.manage"](1, request)
    assert "error" not in response, response.get("error")
    return METHODS["cron.manage"].result.model_validate(response["result"]).model_dump()


def _roster(**params) -> dict:
    from tui_gateway.contracts import METHODS

    response = server._methods["profiles.list"](1, params)
    assert "error" not in response, response.get("error")
    result = METHODS["profiles.list"].result.model_validate(response["result"]).model_dump()
    return {row["name"]: row for row in result["profiles"]}


def _add(profile: str, name: str = "Morning brief", **params) -> dict:
    return _cron("add", profile, name=name, schedule="weekdays at 8:30am", prompt="Summarize my inbox", **params)


def test_a_routine_lists_with_plain_english_schedule_text_and_its_own_time_zone(two_bots):
    created = _add("scout", deliver="bot-chat")
    assert created["success"] is True
    row = _cron("list", "scout")["jobs"][0]
    assert row["name"] == "Morning brief"
    assert row["schedule_text"] == "Weekdays around 8:30 AM"
    assert row["schedule_timezone"] == "Asia/Ho_Chi_Minh"


def test_routines_belong_to_one_bot_only(two_bots):
    _add("scout", deliver="bot-chat")
    assert [job["name"] for job in _cron("list", "scout")["jobs"]] == ["Morning brief"]
    assert _cron("list", "pilot")["jobs"] == []
    with use_cron_store(get_profile_dir("pilot")):
        assert load_jobs() == []


def test_a_routine_added_for_the_bots_chat_delivers_to_that_chat(two_bots):
    _add("scout", deliver="bot-chat")
    with use_cron_store(get_profile_dir("scout")):
        (job,) = load_jobs()
    assert job["deliver"] == "bot-chat"
    from cron.scheduler_delivery import _resolve_delivery_targets

    targets = _resolve_delivery_targets(job)
    assert [(t["platform"], t["chat_id"]) for t in targets] == [("bot-chat", "")]


def test_a_routine_aimed_at_a_bot_that_does_not_exist_is_refused_at_creation(two_bots):
    refused = _add("scout", deliver="bot-chat:ghost")
    assert refused["success"] is False and "ghost" in refused["error"]
    assert _cron("list", "scout")["jobs"] == []


def test_toggling_a_routine_pauses_and_resumes_it_and_moves_the_enabled_count(two_bots):
    _add("scout", deliver="bot-chat")
    _add("scout", name="Evening wrap", deliver="bot-chat")
    assert _roster(include_sessions=False, include_routines=True)["scout"]["routines_enabled"] == 2

    assert _cron("pause", "scout", name="Morning brief")["success"] is True
    assert [job["name"] for job in _cron("list", "scout")["jobs"]] == ["Evening wrap"]
    paused = {job["name"]: job for job in _cron("list", "scout", include_disabled=True)["jobs"]}
    assert paused["Morning brief"]["enabled"] is False and paused["Morning brief"]["state"] == "paused"
    assert paused["Morning brief"]["schedule_text"] == "Weekdays around 8:30 AM"
    assert _roster(include_sessions=False, include_routines=True)["scout"]["routines_enabled"] == 1

    assert _cron("resume", "scout", name="Morning brief")["success"] is True
    assert _roster(include_sessions=False, include_routines=True)["scout"]["routines_enabled"] == 2


def test_the_enabled_count_is_per_bot_and_only_computed_when_asked(two_bots):
    _add("scout", deliver="bot-chat")
    counted = _roster(include_sessions=False, include_routines=True)
    assert counted["scout"]["routines_enabled"] == 1
    assert counted["pilot"]["routines_enabled"] == 0 and counted["default"]["routines_enabled"] == 0
    assert all(row["routines_enabled"] is None for row in _roster(include_sessions=False).values())
    assert not (get_profile_dir("pilot") / "cron" / "jobs.json").exists()


@pytest.mark.parametrize("schedule, text", [
    ({"kind": "cron", "expr": "30 8 * * 1-5"}, "Weekdays around 8:30 AM"),
    ({"kind": "cron", "expr": "0 20 * * *"}, "Every day around 8:00 PM"),
    ({"kind": "cron", "expr": "0 9 * * 6,0"}, "Weekends around 9:00 AM"),
    ({"kind": "cron", "expr": "15 7 * * mon,wed,fri"}, "Mondays, Wednesdays and Fridays around 7:15 AM"),
    ({"kind": "cron", "expr": "0 12 * * 7"}, "Sundays around 12:00 PM"),
    ({"kind": "cron", "expr": "0 0 3 * *"}, "Monthly on the 3rd around 12:00 AM"),
    ({"kind": "cron", "expr": "0 0 22 * *"}, "Monthly on the 22nd around 12:00 AM"),
    ({"kind": "cron", "expr": "15 * * * *"}, "Every hour at :15"),
    ({"kind": "cron", "expr": "*/10 * * * *"}, "Every 10 minutes"),
    ({"kind": "cron", "expr": "0 */6 * * *"}, "Every 6 hours"),
    ({"kind": "interval", "minutes": 30}, "Every 30 minutes"),
    ({"kind": "interval", "minutes": 120}, "Every 2 hours"),
    ({"kind": "interval", "minutes": 1440}, "Every day"),
    ({"kind": "once", "run_at": "2026-11-08T08:30:00+07:00"}, "Once on Nov 8 at 8:30 AM"),
    ({"kind": "cron", "expr": "0 9 1 6 *"}, CUSTOM_SCHEDULE),
    ({"kind": "cron", "expr": "0 9 * * 1/2"}, CUSTOM_SCHEDULE),
    ({"kind": "cron", "expr": "nonsense"}, CUSTOM_SCHEDULE),
    ({"kind": "interval", "minutes": 0}, CUSTOM_SCHEDULE),
    (None, CUSTOM_SCHEDULE),
])
def test_schedules_read_as_plain_english(schedule, text):
    assert describe_schedule(schedule) == text
