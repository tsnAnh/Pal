import json
from unittest.mock import patch

from tests.agent import test_api_content_sidecar as sidecar

wire_env = sidecar.wire_env
_chat_requests, _user_messages = sidecar._chat_requests, sidecar._user_messages

NOTE = '[@mentions resolved from the Bot Mode roster: @faker-kit = agent profile "faker-kit"]'
TYPED = "ask @faker-kit to say hi"


def test_text_turn_sends_the_note_stores_the_typed_row_and_replays_the_sent_bytes(wire_env):
    make_agent, handler, db, sid = wire_env
    make_agent().run_conversation(f"{TYPED}\n\n{NOTE}", conversation_history=[], task_id="t1",
                                  persist_user_message=TYPED)
    sent = _user_messages(_chat_requests(handler)[0])[0]
    assert sent["content"].startswith(f"{TYPED}\n\n{NOTE}")

    [row] = [r for r in db.get_messages(sid) if r["role"] == "user"]
    assert row["content"] == TYPED
    assert row["api_content"] == sent["content"]

    history = db.get_messages_as_conversation(sid)
    handler.captured_requests = []
    make_agent().run_conversation("second question", conversation_history=history, task_id="t2")
    replayed = _user_messages(_chat_requests(handler)[0])[0]
    assert json.dumps(replayed, sort_keys=True) == json.dumps(sent, sort_keys=True)


def test_image_turn_sends_the_note_part_and_stores_the_typed_row(wire_env):
    from run_agent import AIAgent
    make_agent, handler, db, sid = wire_env
    image = {"type": "image_url", "image_url": {"url": "data:image/png;base64,AAAA"}}
    with patch.object(AIAgent, "_model_supports_vision", return_value=True):
        make_agent().run_conversation(
            [{"type": "text", "text": TYPED}, image, {"type": "text", "text": NOTE}], conversation_history=[],
            task_id="t1", persist_user_message=[{"type": "text", "text": TYPED}, image])
    sent = _user_messages(_chat_requests(handler)[0])[0]["content"]
    assert {"type": "text", "text": NOTE} in sent
    [row] = [r for r in db.get_messages(sid) if r["role"] == "user"]
    assert NOTE not in row["content"]
