"""A spoken turn tells the model its reply will be read aloud, per turn, never in the system prompt.

The note rides the model-bound message next to the barge-in and surface notes, so the cached
prefix is untouched and a typed turn in the same session gets nothing.
"""
from types import SimpleNamespace

from gateway.session_surface import surface_note, surface_turn_note, surface_turn_scope
from tools.tts_streaming import SPEECH_INTERRUPTED_NOTE, VOICE_REPLY_NOTE
from tui_gateway import server


def test_spoken_turn_carries_the_voice_reply_note():
    assert surface_note({"voice_turn": True}) == VOICE_REPLY_NOTE


def test_typed_turn_carries_nothing():
    assert surface_note({}) == ""
    assert surface_note({"voice_turn": False}) == ""


def test_note_forbids_the_things_that_cannot_be_spoken():
    lowered = VOICE_REPLY_NOTE.lower()
    for word in ("markdown", "list", "link"):
        assert word in lowered
    assert "short" in lowered


def test_barge_in_note_comes_first_then_the_voice_note():
    note = surface_note({"voice_turn": True, "interrupted": True})

    assert note == f"{SPEECH_INTERRUPTED_NOTE}\n\n{VOICE_REPLY_NOTE}"


def test_voice_live_delegation_is_not_a_chained_voice_turn():
    note = surface_note({"surface": "voice-live", "voice_context": "hi"})

    assert VOICE_REPLY_NOTE not in note


def test_executing_admission_exposes_the_note_to_the_turn():
    agent = SimpleNamespace(valid_tool_names=set())

    with surface_turn_scope({"voice_turn": True}):
        assert surface_turn_note(agent) == VOICE_REPLY_NOTE
    assert surface_turn_note(agent) == ""


def test_tui_gateway_turn_gets_the_note_only_when_marked_spoken():
    session = {"agent": SimpleNamespace(valid_tool_names=set()), "client_surface": ""}

    assert server._hud_surface_note(session, voice_turn=True) == VOICE_REPLY_NOTE
    assert server._hud_surface_note(session) == ""
    assert server._hud_surface_note(session, voice_turn=False) == ""
