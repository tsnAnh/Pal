"""A mid-turn steer is stored wrapped in the model-facing marker; every client-facing read shows the owner's words."""

from agent.prompt_builder import STEER_MARKER_CLOSE, STEER_MARKER_OPEN, steer_user_row
from session_rules.turns import strip_steer_markers, unwrap_steer_text


def test_steer_row_unwraps_to_the_owner_words():
    assert unwrap_steer_text(steer_user_row("hello")["content"]) == "hello"


def test_several_steered_messages_joined_in_one_row_keep_their_lines():
    assert unwrap_steer_text(steer_user_row("first\nsecond")["content"]) == "first\nsecond"


def test_consecutive_wrapped_blocks_in_one_row_unwrap_together():
    content = steer_user_row("first")["content"] + "\n\n" + steer_user_row("second")["content"]
    assert unwrap_steer_text(content) == "first\nsecond"


def test_plain_text_is_unchanged():
    assert unwrap_steer_text("  just a message\n") == "  just a message\n"


def test_marker_quoted_inside_normal_text_is_not_altered():
    quoted = f"he said {STEER_MARKER_OPEN} and then {STEER_MARKER_CLOSE} to me"
    assert unwrap_steer_text(quoted) == quoted


def test_open_marker_without_close_is_not_altered():
    unclosed = f"{STEER_MARKER_OPEN}\nno close"
    assert unwrap_steer_text(unclosed) == unclosed


def test_reworded_opening_line_still_unwraps():
    content = "[OUT-OF-BAND USER MESSAGE: reworded later]\nkeep going\n[/OUT-OF-BAND USER MESSAGE]"
    assert unwrap_steer_text(content) == "keep going"


def test_snippet_loses_whole_markers_only():
    snippet = f"...{STEER_MARKER_OPEN}\nship >>>it<<< now\n{STEER_MARKER_CLOSE}"
    assert strip_steer_markers(snippet) == "...\nship >>>it<<< now\n"
    assert strip_steer_markers("plain >>>hit<<<") == "plain >>>hit<<<"
