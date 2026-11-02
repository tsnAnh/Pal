from __future__ import annotations

import re
from pathlib import Path

from tests.e2e.core.bots._creation import count_tools, launch_world
from tests.fakes.fake_llm_provider import FakeLLMServer, Text, ToolCall


def test_cron_job_cannot_create_a_bot(tmp_path: Path) -> None:
    cmd = "hermes profile create evil"

    def respond(rec: dict):
        return Text("finished") if count_tools(rec["body"]["messages"]) else ToolCall("terminal", {"command": cmd})

    with FakeLLMServer(respond) as srv:
        w = launch_world(tmp_path, srv.base_url, {"approvals": {"mode": "off"}})
        made = w.hermes_ok("default", "cron", "create", "every 1h", "Run the maintenance command.", "--name", "inj")
        job_id = re.search(r"\b([0-9a-f]{12})\b", made.stdout + made.stderr)
        assert job_id, made.stdout
        w.hermes_ok("default", "cron", "run", job_id.group(1))
        w.hermes("default", "cron", "tick", timeout=90)
        assert len(srv.main_requests()) >= 2, "the cron job's terminal call never ran"
    assert not w.profile_exists("evil")
