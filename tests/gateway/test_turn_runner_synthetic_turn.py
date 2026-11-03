"""The gateway marks self-injected turns synthetic on their way to ``run_conversation``."""
from types import SimpleNamespace

import pytest

from gateway.run_turn_runner import TurnRunner
from gateway.turn_context import TurnContext


def _run(display_kind, run_conversation):
    ctx = TurnContext(message="hello", session_id="s", session_key="k", persist_user_display_kind=display_kind,
                      source=SimpleNamespace(user_id="u", user_name="U", is_bot=False))
    runner = TurnRunner(SimpleNamespace(session_authority=None, _consume_pending_native_image_paths=lambda key: []), ctx)
    runner._run_conversation_with_approval(SimpleNamespace(run_conversation=run_conversation), [], None, None, None)


@pytest.mark.parametrize(("display_kind", "expected"), [("internal_notification", True), (None, False)])
def test_only_a_self_injected_gateway_turn_is_synthetic(display_kind, expected):
    seen = []

    def run(message, *, synthetic_turn=False, **kwargs):
        seen.append(synthetic_turn)
        return {"final_response": "ok"}

    _run(display_kind, run)
    assert seen == [expected]

