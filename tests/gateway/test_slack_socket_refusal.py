import asyncio
from types import SimpleNamespace

import pytest

from tests.gateway.test_slack import SlackAdapter


class _Refused(Exception):
    def __init__(self, response):
        super().__init__("The request to the Slack API failed.")
        self.response = response


def _adapter(monkeypatch):
    adapter = object.__new__(SlackAdapter)
    writes = []
    monkeypatch.setattr(SlackAdapter, "_write_runtime_status_safe",
                        lambda self, context, **fields: writes.append((context, fields)), raising=False)
    return adapter, writes


def test_a_missing_scope_refusal_publishes_slacks_code_and_the_scopes(monkeypatch):
    adapter, writes = _adapter(monkeypatch)
    adapter._publish_socket_refusal(_Refused(
        {"ok": False, "error": "missing_scope", "needed": "connections:write", "provided": "authorizations:read"}))
    [(context, fields)] = writes
    assert context == "socket_refused" and fields["platform_state"] == "retrying"
    assert fields["error_code"] == "missing_scope"
    assert fields["needed_scope"] == "connections:write" and fields["provided_scope"] == "authorizations:read"
    assert "xapp-" not in repr(fields)


def test_a_refusal_found_on_the_cause_is_published(monkeypatch):
    adapter, writes = _adapter(monkeypatch)
    wrapper = RuntimeError("socket task failed")
    wrapper.__cause__ = _Refused({"ok": False, "error": "invalid_auth"})
    adapter._publish_socket_refusal(wrapper)
    assert writes[0][1]["error_code"] == "invalid_auth" and writes[0][1]["needed_scope"] is None


@pytest.mark.parametrize("exc", [RuntimeError("boom"), _Refused({"ok": False}), _Refused(None), _Refused("text")])
def test_errors_without_a_slack_code_publish_nothing(monkeypatch, exc):
    adapter, writes = _adapter(monkeypatch)
    adapter._publish_socket_refusal(exc)
    assert writes == []


def test_the_task_done_callback_publishes_the_refusal(monkeypatch):
    adapter, writes = _adapter(monkeypatch)
    adapter._running = True
    adapter._socket_mode_task = None

    async def run():
        async def fail():
            raise _Refused({"ok": False, "error": "token_revoked"})

        task = asyncio.ensure_future(fail())
        adapter._socket_mode_task = task
        await asyncio.wait({task})
        monkeypatch.setattr(adapter, "_restart_socket_mode", lambda reason: asyncio.sleep(0), raising=False)
        adapter._on_socket_mode_task_done(task)

    asyncio.run(run())
    assert writes and writes[0][1]["error_code"] == "token_revoked"
