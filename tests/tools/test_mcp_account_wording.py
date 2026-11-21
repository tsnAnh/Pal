from __future__ import annotations

import json

import pytest

from tools import mcp_action_gate
from tools.auth_required import detect, reauth_reason, reauth_required_result, service_display_name
from tools.mcp_accounts import display_name, service_for_server, split_service
from tools.tool_labels import label_for_tool_name


def test_a_tool_label_names_the_account_the_call_asked_for():
    labelled = label_for_tool_name("mcp__linear__list_issues", {"connector_alias": "work"})
    plain = label_for_tool_name("mcp__linear__list_issues", {"limit": 5})

    assert (labelled.app, labelled.action) == ("Linear", "list issues (work)")
    assert (plain.app, plain.action) == ("Linear", "list issues")
    assert label_for_tool_name("mcp__linear__list_issues", {"connector_alias": "  "}).action == "list issues"


def test_a_sign_in_prompt_and_the_reauth_reason_name_the_account():
    assert service_display_name("mcp:upwork:work") == "Upwork (work)"
    assert service_display_name("mcp:upwork") == "Upwork"
    assert service_display_name("mcp:hugging_face:side-gig") == "Hugging Face (side-gig)"
    assert reauth_reason("upwork@work") == "Sign in again: Upwork (work) stopped accepting the saved sign-in"
    assert reauth_reason("upwork") == "Sign in again: Upwork stopped accepting the saved sign-in"


def test_the_typed_reauth_error_of_an_account_becomes_a_need_for_that_account_only():
    result = reauth_required_result("upwork@work")

    need = detect("mcp__upwork__search_jobs", {}, result)

    assert need.service == "mcp:upwork:work" and need.blocking is False
    assert json.loads(result)["server"] == "upwork@work"
    plain = detect("mcp__custom__x", {}, reauth_required_result("custom"))
    assert plain.service == "mcp:custom"


@pytest.mark.parametrize("name,service", [("upwork@work", "mcp:upwork:work"), ("custom", "mcp:custom"),
                                          ("odd@Name", "mcp:odd@Name")])
def test_a_connection_name_and_its_service_name_map_both_ways(name, service):
    assert service_for_server(name) == service
    parsed = split_service(service)
    assert (parsed is not None and parsed[1] is not None) == (name == "upwork@work")


def test_the_display_name_of_a_plain_server_is_unchanged_and_an_accounts_is_plain_words():
    assert display_name("faket3") == "faket3"
    assert display_name("upwork@work") == "Upwork (work)"


def test_an_approval_card_names_the_account_without_the_internal_name():
    card = mcp_action_gate.build_card("upwork@work", "submit_proposal", {"cover_letter": "Hi"})

    assert card["draft"]["channel"] == "Upwork (work)"
    assert "Upwork (work)" in card["description"] and "@" not in json.dumps(card)
