"""What the agent receives for answers resolved through ``resolve_gateway_clarify``.

The Pal app's multi-select Confirm sends the picked indices as a raw "1,2" string; older builds do
too. The agent must get choice texts, never an index string it cannot map back.
"""

import json

import pytest

from tools import clarify_gateway as cm
from tools.clarify_tool import _clean_answer

CHOICES = ["staging", "prod", "canary"]


def _agent_receives(response, *, multi, choices=CHOICES):
    entry = cm.register("cid", "sess", "where?", choices, multi_select=multi)
    try:
        assert cm.resolve_gateway_clarify("cid", response)
        return _clean_answer(entry.response, entry.multi_select)
    finally:
        cm._entries.pop("cid", None)
        cm._session_index.pop("sess", None)


@pytest.mark.parametrize("sent,expected", [
    ("1,2", ["staging", "prod"]),
    ("3", ["canary"]),
    ("2, 1", ["prod", "staging"]),
    ("2,2", ["prod"]),
])
def test_multi_select_indices_become_choice_texts(sent, expected):
    assert _agent_receives(sent, multi=True) == expected


@pytest.mark.parametrize("sent", ["1,9", "0,1", "1,x", "staging", json.dumps(["prod"]) + "x"])
def test_multi_select_out_of_range_or_typed_text_is_kept_as_typed(sent):
    assert _agent_receives(sent, multi=True) == [sent]


def test_multi_select_json_array_from_typed_reply_is_untouched():
    assert _agent_receives(json.dumps(["prod", "canary"]), multi=True) == ["prod", "canary"]


def test_single_select_choice_text_and_free_text_look_alike_are_untouched():
    assert _agent_receives("prod", multi=False) == "prod"
    assert _agent_receives("1,2", multi=False) == "1,2"


def test_open_ended_question_never_maps_indices():
    assert _agent_receives("1,2", multi=True, choices=None) == "1,2"
