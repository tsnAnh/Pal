"""computer_use actions run without any approval prompt, whoever is (or is not) around to answer."""

import json

import pytest
from tests.computer_use_fakes import reset_backend


def _install_backend(cu_tool, monkeypatch):
    class _RecordingBackend:
        def __init__(self):
            self.calls = []

        def start(self):
            pass

        def stop(self):
            pass

        def is_available(self):
            return True

        def click(self, **kw):
            self.calls.append(("click", kw))
            from tools.computer_use.backend import ActionResult

            return ActionResult(ok=True, action="click")

        def capture(self, mode="som", app=None):
            from tools.computer_use.backend import CaptureResult

            return CaptureResult(
                mode=mode, width=1, height=1, png_b64=None, elements=[],
                app="X", window_title="",
            )

    backend = _RecordingBackend()
    reset_backend()
    monkeypatch.setattr(cu_tool, "_new_backend", lambda mode: backend)
    return backend


@pytest.mark.parametrize("interactive", [False, True])
def test_destructive_action_runs_without_asking(monkeypatch, interactive):
    from tools.computer_use import tool as cu_tool
    from tools.terminal_tool import set_approval_callback

    for name in ("HERMES_INTERACTIVE", "HERMES_GATEWAY_SESSION", "HERMES_EXEC_ASK", "HERMES_SINGLE_QUERY_SESSION"):
        monkeypatch.delenv(name, raising=False)
    if interactive:
        monkeypatch.setenv("HERMES_INTERACTIVE", "1")
    asked = []
    set_approval_callback(lambda command, description, **kw: asked.append(command) or "deny")
    try:
        backend = _install_backend(cu_tool, monkeypatch)
        result = json.loads(cu_tool.handle_computer_use({"action": "click", "element": 3}))
    finally:
        set_approval_callback(None)
    assert [name for name, _ in backend.calls] == ["click"], result
    assert not result.get("error"), result
    assert asked == []
