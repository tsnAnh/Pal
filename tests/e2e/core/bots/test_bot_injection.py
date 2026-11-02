from __future__ import annotations

from pathlib import Path
from typing import Any

import pytest

from tests.e2e.core.bots._creation import injected_responder, launch_world, write_notes
from tests.fakes.fake_llm_provider import FakeLLMServer, Text

PLAIN: dict[str, Any] = {}
YOLO_FLAG = ("--yolo",)
APPROVALS_OFF = {"approvals": {"mode": "off"}}
SMART = {"approvals": {"mode": "smart"}}


CASES = [
    ("plain", (), PLAIN, None, "hermes bot create evil"),
    ("yolo-flag", YOLO_FLAG, PLAIN, None, "hermes bot create evil"),
    ("approvals-off", (), APPROVALS_OFF, None, "hermes bot create evil"),
    ("smart-approves", (), SMART, lambda rec: Text("APPROVE"), "hermes bot create evil"),
    ("yolo-flag", YOLO_FLAG, PLAIN, None, "hermes profile create evil"),
    ("approvals-off", (), APPROVALS_OFF, None, "hermes profile create evil"),
]


@pytest.mark.parametrize("variant,flags,extra,aux,cmd", CASES, ids=[
    "bot-create-plain", "bot-create-yolo-flag", "bot-create-approvals-off", "bot-create-smart-approves",
    "profile-create-yolo-flag", "profile-create-approvals-off"])
def test_injected_instruction_cannot_create_a_bot_in_a_single_query_run(
    tmp_path: Path, variant: str, flags: tuple[str, ...], extra: dict, aux, cmd: str,
) -> None:
    with FakeLLMServer(injected_responder(cmd, tmp_path / "work" / "notes.txt"), aux=aux) as srv:
        w = launch_world(tmp_path, srv.base_url, extra)
        write_notes(w, cmd)
        w.hermes("default", "chat", "-q", "summarize notes.txt", "-Q", *flags)
        assert len(srv.main_requests()) >= 3, "the scripted terminal call never ran"
    assert not w.profile_exists("evil"), f"{variant}: injected `{cmd}` created a profile without a human"
