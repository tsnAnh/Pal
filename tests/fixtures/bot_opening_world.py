from __future__ import annotations

import json
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

from hermes_cli.bot_onboarding import mark_onboarding_pending, read_onboarding_pending
from hermes_cli.profiles import write_profile_meta
from persistence_assembly import open_persistence, profile_scope
from run_agent import AIAgent
from tests.fixtures.storage_read import conversation
from tests.fixtures.storage_seed import seed_session
from tools.bot_mode_about_you import write_about_you
from tools.clarify_tool import CLARIFY_SCHEMA

SESSION_ID = "bot-chat-1"
INTRO = "The owner just opened this chat. Greet them."
MODEL_REPLY = "Got it. I'll set that up."


class BotWorld:
    def __init__(self, tmp_path: Path, monkeypatch, *, pending: bool = True, role: bool = False,
                 owner: str | None = "Sam", display_name: str = "Ada", answer: str | None = "Help with my apps and work",
                 shared_launch_store: bool = False):
        self.root = tmp_path / ".hermes"
        self.root.mkdir()
        monkeypatch.setattr(Path, "home", lambda: tmp_path)
        monkeypatch.setenv("HERMES_HOME", str(self.root))
        self.profile = self.root / "profiles" / "ada"
        self.profile.mkdir(parents=True)
        write_profile_meta(self.profile, display_name=display_name)
        if owner:
            write_about_you(self.root, name=owner)
        if pending:
            mark_onboarding_pending(self.profile)
        if role:
            (self.profile / "SOUL.md").write_text("# Ada\n\n## Role\nRuns my inbox.\n", encoding="utf-8")
        self.db = open_persistence(profile_scope(home=self.root if shared_launch_store else self.profile))
        self.events: list[str] = []
        self.asked: list[dict] = []
        self.model_requests: list[list[dict]] = []
        self.answer = answer
        self.agent = self._agent()

    def close(self) -> None:
        self.db.close()

    @property
    def pending(self) -> bool:
        return read_onboarding_pending(self.profile)

    def rows(self) -> list[dict]:
        return conversation(self.db, SESSION_ID)

    def _clarify(self, questions: list[dict]) -> dict:
        self.events.append("card")
        self.asked.extend(questions)
        answers = {} if self.answer is None else {questions[0]["qid"]: self.answer}
        return {"answers": answers, "outcome": "submitted"}

    def _model(self, **kwargs):
        self.events.append("model")
        self.model_requests.append(kwargs["messages"])
        return SimpleNamespace(
            choices=[SimpleNamespace(message=SimpleNamespace(content=MODEL_REPLY, tool_calls=None), finish_reason="stop")],
            model="test/model", usage=None)

    def _agent(self) -> AIAgent:
        tool_defs = [{"type": "function", "function": CLARIFY_SCHEMA}]
        with (
            patch("model_tools.get_tool_definitions", return_value=tool_defs),
            patch("model_tools.check_toolset_requirements", return_value={}),
            patch("agent.process_bootstrap.OpenAI"),
            patch("run_agent._hermes_home", self.profile),
            patch("agent.model_metadata.fetch_model_metadata", return_value={}),
        ):
            agent = AIAgent(api_key="test-key", base_url="https://openrouter.ai/api/v1", quiet_mode=True,
                            skip_context_files=True, skip_memory=True)
        agent.client = MagicMock()
        agent.client.chat.completions.create.side_effect = self._model
        agent._cached_system_prompt = "You are helpful."
        agent._use_prompt_caching = False
        agent.compression_enabled = False
        agent.save_trajectories = False
        agent.clarify_callback = self._clarify
        seed_session(self.db, SESSION_ID, "gui", model="test/model")
        agent._session_db = agent.persistence = self.db
        agent._session_db_created = True
        agent.session_id = SESSION_ID
        agent._last_flushed_db_idx = 0
        agent._flushed_db_message_ids = set()
        agent._flushed_db_message_session_id = None
        agent._persist_disabled = False
        return agent

    def play(self, prelude, *, hidden: bool = True) -> dict:
        kwargs = {"persist_user_display_kind": "hidden", "synthetic_turn": True} if hidden else {}
        with patch("agent.title_generator.maybe_auto_title", lambda *args, **kw: None):
            return self.agent.run_conversation(INTRO, conversation_history=[], prelude=prelude, **kwargs)

    def clarify_call(self) -> dict:
        assistant = next(row for row in self.rows() if row["role"] == "assistant" and row.get("tool_calls"))
        return json.loads(assistant["tool_calls"][0]["function"]["arguments"])
