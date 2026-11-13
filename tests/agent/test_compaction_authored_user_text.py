"""The todo snapshot and skill-reload notice compaction adds are model-only: a standalone row is stamped
hidden and one folded onto a real user row carries the ask it was folded onto, so a transcript view shows
the user's words and never the scaffolding."""

from tests.agent.test_skill_todo_retention_parity import _build_agent_with_db, _msgs

from agent.context_compressor import _skill_pruned_marker
from agent.conversation_compression import _PRUNED_SKILL_RELOAD_NOTICE_HEADER, _fold_todo_snapshot
from agent.message_metadata import authored_user_text
from hermes_state import SessionDB
from tools.todo_tool import TODO_INJECTION_HEADER

ASK = "tail ask"


def _agent(tmp_path):
    db = SessionDB(db_path=tmp_path / "state.db")
    db.create_session("parent", source="cli")
    agent = _build_agent_with_db(db, "parent")
    agent._todo_store._items = [{"id": "t1", "content": "task A", "status": "pending"}]
    return db, agent


def test_standalone_snapshot_row_is_stored_hidden(tmp_path):
    db, agent = _agent(tmp_path)
    summary = "[CONTEXT COMPACTION] summary\n\n## Pruned Skills\n" + _skill_pruned_marker("chief")
    agent.context_compressor.compress.return_value = [
        {"role": "user", "content": summary}, {"role": "assistant", "content": "acknowledged"}]
    agent._compress_context(_msgs(), "sys", approx_tokens=120_000)

    stored = [row for row in db.get_messages_as_conversation(agent.session_id)
              if row["role"] == "user" and TODO_INJECTION_HEADER in row["content"]]
    assert len(stored) == 1 and _PRUNED_SKILL_RELOAD_NOTICE_HEADER in stored[0]["content"]
    assert stored[0]["display_kind"] == "hidden"


def test_snapshot_folded_onto_a_real_user_row_names_the_ask(tmp_path):
    _db, agent = _agent(tmp_path)
    compressed = [{"role": "assistant", "content": "ok"}, {"role": "user", "content": ASK}]
    _fold_todo_snapshot(agent, compressed)
    folded = compressed[-1]
    assert TODO_INJECTION_HEADER in folded["content"] and folded["content"].startswith(ASK)
    assert authored_user_text(folded, folded["content"]) == ASK


def test_a_user_row_quoting_the_snapshot_header_without_provenance_is_untouched():
    quoted = f"{ASK}\n\n{TODO_INJECTION_HEADER}\n- [ ] 1. mine"
    assert authored_user_text({"role": "user", "content": quoted}, quoted) is None
