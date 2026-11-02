import sys

import pytest

import tools.process_registry as module
from tools.process_registry import InternalProcessPolicy, ProcessRegistry
from tui_gateway import server


@pytest.mark.platforms("posix")
def test_slash_stop_spares_internal_runners(monkeypatch):
    registry = ProcessRegistry()
    monkeypatch.setattr(module, "process_registry", registry)
    sleeper = f"{sys.executable} -c 'import time; time.sleep(60)'"
    user = registry.spawn_local(sleeper, task_id="t", session_key="chat-key")
    runner = registry.spawn_local(sleeper, task_id="t", session_key="chat-key",
                                  internal_policy=InternalProcessPolicy(max_lifetime_seconds=3420))
    try:
        server._mirror_slash_side_effects("ui-chat", {"session_key": "chat-key"}, "/stop")

        assert user.exited and not runner.exited
    finally:
        registry.kill_all()
