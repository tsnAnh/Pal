"""The `commitment` tool's standing-duty verbs: a schema generated from the enums, the owner-only acceptance, and a
clear refusal on every bot that is not the primary one."""

import json

import pytest

import tools.commitment_tool as tool
from gateway import commitments as cm
from gateway.autonomy import ActionClass
from gateway.commitments import Trigger
from gateway.session_context import clear_session_vars, set_session_vars
from tools.approval_context import reset_current_observability_context, set_current_observability_context
from tools.registry import registry

VERBS = ("propose_mandate", "accept", "pause", "resume", "dismiss", "list_mandates")


@pytest.fixture
def primary(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    monkeypatch.setattr("hermes_cli.primary_profile.primary_profile_name", lambda: "main")
    tokens = set_session_vars(platform="telegram", chat_id="42", chat_type="dm", thread_id="7",
                              session_key="agent:main:telegram:dm:42", session_id="s1", profile="main")
    yield tmp_path
    clear_session_vars(tokens)


def call(args: dict, *, tool_call_id: str = "") -> dict:
    tokens = set_current_observability_context(turn_id="t1" if tool_call_id else "", tool_call_id=tool_call_id,
                                               session_id="s1" if tool_call_id else "")
    try:
        return json.loads(registry.dispatch("commitment", args))
    finally:
        reset_current_observability_context(tokens)


def propose(*, tool_call_id: str = "", **extra) -> dict:
    return call({"action": "propose_mandate", "text": "Build the Mac app when a Pal PR merges", "owner_requested": False,
                 "trigger": "pr_merged", "action_class": "run_tools", "done_when": "the app is installed", **extra},
                tool_call_id=tool_call_id)


def accepted_duty() -> dict:
    made = propose()
    return call({"action": "accept", "id": made["id"], "owner_requested": True})


def enum_of(schema: dict, name: str) -> list[str]:
    return schema["parameters"]["properties"][name]["enum"]


def test_the_schema_derives_every_new_enum_from_the_ledger():
    schema = tool.build_schema()
    assert registry.get_schema("commitment") == schema == tool.COMMITMENT_SCHEMA
    assert enum_of(schema, "trigger") == [t.value for t in Trigger]
    assert enum_of(schema, "action_class") == [a.value for a in ActionClass]
    assert set(VERBS) <= set(enum_of(schema, "action"))
    assert {"promise", "update", "close", "list"} <= set(enum_of(schema, "action"))


def test_a_proposal_is_recorded_unaccepted_with_the_chat_it_came_from(primary):
    made = propose()
    assert made["standing"] == "proposed"
    row = cm.get(primary, made["id"])
    assert (row.kind, row.route.chat_id, row.profile, row.owner_requested) == (cm.Kind.PROPOSAL, "42", "main", False)


def test_the_same_tool_call_proposes_once(primary):
    first, second = propose(tool_call_id="c1"), propose(tool_call_id="c1")
    assert (second["id"], second["replayed"]) == (first["id"], True)
    assert propose()["id"] != first["id"]
    assert len(cm.list_mandates(primary)) == 2


@pytest.mark.parametrize("bad", [{"trigger": "sunrise"}, {"action_class": "launch_missiles"}, {"trigger": None},
                                 {"done_when": ""}, {"owner_requested": "yes"}])
def test_a_proposal_with_an_unknown_or_missing_field_is_refused(primary, bad):
    assert call({"action": "propose_mandate", "text": "t", "owner_requested": False, "trigger": "ci_red",
                 "action_class": "run_tools", "done_when": "d", **bad})["code"] == "invalid_input"
    assert cm.list_mandates(primary) == []


def test_the_model_alone_cannot_accept(primary):
    made = propose()
    refused = call({"action": "accept", "id": made["id"]})
    assert refused["code"] == "owner_only"
    assert call({"action": "accept", "id": made["id"], "owner_requested": False})["code"] == "owner_only"
    assert cm.get(primary, made["id"]).kind is cm.Kind.PROPOSAL


def test_an_accept_the_owner_asked_for_in_the_turn_activates_it_as_the_owner(primary):
    duty = accepted_duty()
    assert duty["standing"] == "active"
    assert cm.events(primary, duty["id"])[-1].actor is cm.Actor.OWNER


def test_a_retried_accept_is_one_acceptance(primary):
    made = propose()
    args = {"action": "accept", "id": made["id"], "owner_requested": True}
    first, second = call(args, tool_call_id="tap"), call(args, tool_call_id="tap")
    assert (first.get("replayed"), second["replayed"], second["rev"]) == (None, True, 2)


def test_pause_resume_and_dismiss_walk_the_lifecycle(primary):
    duty = accepted_duty()
    assert call({"action": "pause", "id": duty["id"]})["standing"] == "paused"
    assert call({"action": "resume", "id": duty["id"]})["standing"] == "active"
    gone = call({"action": "dismiss", "id": duty["id"], "reason": "too noisy"})
    assert (gone["standing"], gone["dismissed"]) == ("dismissed", 1)
    assert call({"action": "pause", "id": duty["id"]})["code"] == "illegal_edge"
    assert call({"action": "list_mandates"})["mandates"] == []


def test_a_stale_expected_rev_is_refused(primary):
    made = propose()
    assert call({"action": "accept", "id": made["id"], "owner_requested": True, "expected_rev": 9})["code"] == "rev_conflict"


def test_list_mandates_shows_duties_and_list_keeps_showing_promises_only(primary):
    call({"action": "promise", "text": "Send the weekly report", "owner_requested": True})
    duty = accepted_duty()
    listed = call({"action": "list_mandates"})["mandates"]
    assert [(d["id"], d["standing"], d["trigger"], d["action_class"]) for d in listed] == [
        (duty["id"], "active", "pr_merged", "run_tools")]
    assert [c["promise"] for c in call({"action": "list"})["commitments"]] == ["Send the weekly report"]


@pytest.mark.parametrize("verb", VERBS)
def test_a_bot_that_is_not_primary_refuses_every_duty_verb_and_writes_nothing(primary, monkeypatch, verb):
    monkeypatch.setattr("hermes_cli.primary_profile.primary_profile_name", lambda: "boss")
    refused = call({"action": verb, "id": "cm_x", "text": "t", "trigger": "ci_red", "action_class": "run_tools",
                    "done_when": "d", "owner_requested": True})
    assert refused["code"] == "not_primary_profile"
    assert cm.list_mandates(primary) == []


def test_a_bot_that_is_not_primary_keeps_its_promises(primary, monkeypatch):
    monkeypatch.setattr("hermes_cli.primary_profile.primary_profile_name", lambda: "boss")
    made = call({"action": "promise", "text": "Send the weekly report", "owner_requested": True})
    assert made["state"] == "open"
    assert len(call({"action": "list"})["commitments"]) == 1
