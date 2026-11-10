"""``input.absorbed`` names the turn it landed in and moves the reply cursor: the next delta is a new segment."""
from tui_gateway.stream_segments import TurnSegments, stamp_reply_frame


def test_the_frame_carries_the_turn_id_and_the_next_delta_opens_a_new_segment():
    segments = TurnSegments()
    stamp_reply_frame(segments, "message.start", {})
    first = stamp_reply_frame(segments, "message.delta", {"text": "Checking the merge"})
    absorbed = stamp_reply_frame(segments, "input.absorbed", {
        "admission_ids": ["adm_1"], "message_uid": "uid_1", "text": "what is the weather?"})
    second = stamp_reply_frame(segments, "message.delta", {"text": "It is 24 degrees"})

    assert absorbed["turn_id"] == segments.turn_id == first["turn_id"] == second["turn_id"]
    assert absorbed["admission_ids"] == ["adm_1"] and absorbed["text"] == "what is the weather?"
    assert (first["segment"], first["offset"]) == (0, 0)
    assert (second["segment"], second["offset"]) == (1, 0)
