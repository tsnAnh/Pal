"""MCP targets of manage_connections (the fold that retired setup_mcp).

Contracts:
- the backend owns the work: authorize mints its own URL, install writes credentials and installs,
  enable flips the flag; enable asks nothing, install asks the owner through the question form first,
  and the card only reports progress, takes the credentials a waiting install asked for, and Try again
- a card claim of any other state moves nothing
- off the desktop there is no card: the work runs at once and the result carries the link
- catalog validation: install is catalog-only, enable/authorize need a configured server
- the replay shim keeps an old ``setup_mcp`` call dispatching
- deadline ownership: fixed operation deadline + sequential-deadline exemption
"""

import contextlib
import json
import threading
from types import SimpleNamespace
from unittest.mock import patch

import pytest

from tools.connectors.contract import SettleReason, TargetState
from tools.connectors import live
from tools.connectors.mcp import apply_answer
from tools.connectors.tool import manage_connections
from tools.registry import registry

CATALOG = ["figma", "linear", "notion"]
CONFIGURED = {"paper": {"command": "paper-mcp"}, "linear": {"url": "https://mcp.linear.app/mcp"}}


class FakeAttempt:
    """An OAuth flow in flight, as the watcher reads it."""

    def __init__(self, auth_url):
        self.auth_url = auth_url
        self.status = "pending"
        self.error = ""
        self.tools = []
        self.discovery_error = ""

    def poll(self):
        return {"status": self.status, "error": self.error, "tools": list(self.tools),
                "discovery_error": self.discovery_error}

    def approve(self, tools):
        self.tools, self.status = list(tools), "approved"

    def fail(self, error):
        self.error, self.status = error, "error"


class FakeBackend:
    """The one fake: the catalog, the installer and the OAuth flow runner behind ``mcp.py``."""

    def __init__(self, *, missing_env=(), tools=("read", "write"), registered_tools=(),
                 install_error="", registration_error="", oauth_error=""):
        self.calls = []
        self.attempts = {}
        self.missing_env = list(missing_env)
        self.tools = list(tools)
        self.registered_tools = list(registered_tools)
        self.install_error = install_error
        self.registration_error = registration_error
        self.oauth_error = oauth_error

    def required_env(self, name):
        self.calls.append(("required_env", name))
        return [{"name": key, "prompt": f"{key}?", "required": True,
                 "secret": True, "default": ""} for key in self.missing_env]

    def start_oauth(self, name):
        self.calls.append(("start_oauth", name))
        if self.oauth_error:
            raise RuntimeError(self.oauth_error)
        attempt = FakeAttempt(f"https://auth.example/{name}/{len(self.attempts) + 1}")
        self.attempts[name] = attempt
        return attempt

    def install(self, name, env):
        self.calls.append(("install", name, dict(env)))
        if self.install_error:
            raise RuntimeError(self.install_error)
        return list(self.tools)

    def enable(self, name):
        self.calls.append(("enable", name))


@pytest.fixture
def backend():
    return FakeBackend()


@pytest.fixture(autouse=True)
def _clean_live():
    live._open.clear()
    yield
    live._open.clear()


@pytest.fixture(autouse=True)
def _catalog(backend):
    # The default backend is patched too: a call that cannot be handed one (registry dispatch, the
    # inline executor) must never reach the real catalog or installer from a test.
    registered = []

    def register(runner, target, name):
        runner.backend.calls.append(("register", name))
        if runner.backend.registration_error:
            from tools.connectors.mcp import _detail

            return [], _detail(runner.backend.registration_error, runner, target)
        names = list(runner.backend.registered_tools)
        for tool_name in names:
            registry.register(
                name=tool_name,
                toolset=f"mcp-{name}",
                schema={"name": tool_name, "description": f"Registered {tool_name}", "parameters": {}},
                handler=lambda *_args, **_kwargs: "{}",
            )
            registered.append(tool_name)
        return names, ""

    with patch("tools.connectors.mcp._catalog_names", return_value=CATALOG), \
         patch("tools.connectors.mcp._configured_names", return_value=sorted(CONFIGURED)), \
         patch("tools.connectors.mcp._default_backend", return_value=backend), \
         patch("tools.connectors.mcp._register_connected", side_effect=register):
        yield
    with registry._lock:
        for tool_name in registered:
            registry._tools.pop(tool_name, None)
        if registered:
            registry._generation += 1


class FakeClient:
    def __init__(self):
        self.calls = []

    def list_connectors(self, **_):
        self.calls.append("list")
        return [{"connector": "gmail", "enabled": True, "connected": False}]

    def connections(self, connectors, *, reinitiate=False):
        self.calls.append(("connections", tuple(connectors), reinitiate))
        return {"results": [{"connector": c, "status": "initiated", "connect_url": f"https://x/{c}"} for c in connectors]}


def _mcp_target(name):
    return {"name": name, "mcp": True}


def _linear(**kw):
    return {"name": "linear", "mcp": True, **kw}


class FormAsker:
    """The clarify callback a surface binds for the tool call: records every question it is shown
    and answers each one with ``pick`` (a label, or None for no answer)."""

    def __init__(self, pick="Install and set up (Recommended)", outcome="submitted"):
        self.pick, self.outcome = pick, outcome
        self.asked = []
        self.details = []

    def __call__(self, questions):
        self.asked.append(questions)
        return {"answers": {q["qid"]: self.pick for q in questions}, "outcome": self.outcome}

    def sink(self, text):
        self.details.append(text)
        return True


@contextlib.contextmanager
def _asking(asker):
    from tools.details_bubble import bound_details_sink
    from tools.mcp_elicitation_form import bound_form_asker

    with bound_form_asker(asker), bound_details_sink(getattr(asker, "sink", None)):
        yield


@pytest.fixture(autouse=True)
def _attended():
    with patch("tools.approval_context._no_user_can_answer", return_value=False), \
         patch("tools.connectors.install_form._entry", return_value=SimpleNamespace(
             description="Issue tracking. Plans and tracks work.",
             auth=SimpleNamespace(type="api_key", env=[SimpleNamespace(name="LINEAR_API_KEY", prompt="a Linear API key",
                                                                        required=True)]))), \
         patch("tools.connectors.mcp_launch.launch_for", return_value={"kind": "remote", "target": "https://mcp.linear.app/mcp"}):
        yield


# ---------------------------------------------------------------------------
# the card round-trip: the backend does the work, the card answers approved / skipped
# ---------------------------------------------------------------------------


def _answering(answer, *, session_id="s1", delay=0.01):
    """A card that emits (callback returns None) and answers the live operation a moment later,
    the way ``connection.respond`` does from the renderer."""
    seen = []

    def callback(payload):
        seen.append(payload)

        def respond():
            operation = live.get(session_id, payload["op_id"])
            if operation is not None:
                apply_answer(operation, answer)

        if answer is not None:
            threading.Timer(delay, respond).start()

    callback.seen = seen
    return callback


def _mcp(args, callback, **kw):
    with patch("tools.connectors.run.WATCH_INTERVAL_SECONDS", 0.01):
        return json.loads(manage_connections(args, connection_callback=callback, session_id="s1", **kw))


def test_install_waits_for_the_credentials_it_declares_and_installs_with_them():
    backend = FakeBackend(
        missing_env=["FIGMA_TOKEN"], tools=["probe_only"],
        registered_tools=["mcp__figma__get_file", "mcp__figma__list_files"],
    )
    answer = json.dumps({"targets": [{"name": "figma", "status": "approved", "env": {"FIGMA_TOKEN": "tok-1"}}]})
    callback = _answering(answer)
    with _asking(FormAsker()):
        out = _mcp({"action": "install", "connectors": [_mcp_target("figma")]}, callback, mcp_backend=backend)

    (offered,) = callback.seen[0]["targets"]
    assert offered["state"] == TargetState.pending.value
    assert offered["required_env"] == [{"name": "FIGMA_TOKEN", "prompt": "FIGMA_TOKEN?",
                                        "required": True, "secret": True, "default": ""}]
    assert ("install", "figma", {"FIGMA_TOKEN": "tok-1"}) in backend.calls
    (settled,) = out["targets"]
    assert settled["state"] == TargetState.connected.value
    assert settled["tools"] == ["mcp__figma__get_file", "mcp__figma__list_files"]
    assert all(name in settled["tools_listing"] for name in settled["tools"])
    assert "tool_describe" in settled["tools_listing"] and "tool_call" in settled["tools_listing"]


def test_a_card_claim_other_than_approved_moves_nothing(backend):
    answer = json.dumps({"targets": [{"name": "paper", "status": "connected", "tools": ["x"]}],
                         "settled_by": "continue"})
    out = _mcp({"action": "authorize", "connectors": [_mcp_target("paper")]}, _answering(answer), mcp_backend=backend)

    assert backend.calls == [("start_oauth", "paper")]
    (settled,) = out["targets"]
    assert settled["state"] == TargetState.not_connected.value
    assert out["settled_by"] == SettleReason.continue_.value


def test_no_answer_settles_by_deadline_and_marks_targets_not_connected(backend):
    with patch("tools.connectors.operation.OPERATION_DEADLINE_SECONDS", 0.05):
        out = _mcp({"action": "authorize", "connectors": [_linear()]}, _answering(None), mcp_backend=backend)
    assert out["settled_by"] == SettleReason.deadline.value
    assert out["targets"][0]["state"] == TargetState.not_connected.value
    assert "error" not in out


def test_mcp_secrets_never_reach_the_model():
    backend = FakeBackend(missing_env=["LINEAR_API_KEY"], registration_error="sk-secret was rejected")
    answer = json.dumps({"targets": [{"name": "linear", "status": "approved",
                                      "env": {"LINEAR_API_KEY": "sk-secret"}}]})
    with _asking(FormAsker()):
        out = _mcp({"action": "install", "connectors": [_linear()]}, _answering(answer), mcp_backend=backend)
    payload = json.dumps(out)
    assert "sk-secret" not in payload
    assert "[REDACTED]" in payload
    assert out["targets"][0]["state"] == TargetState.connected.value
    assert out["targets"][0]["tools"] == []
    assert out["targets"][0]["discovery_error"] == "[REDACTED] was rejected"


# ---------------------------------------------------------------------------
# no consent step: an installed connector turns on, a new one asks through the question form
# ---------------------------------------------------------------------------

_BANNED = ("allow", "deny", "don't allow")


def test_enabling_an_installed_connector_settles_connected_with_no_card_and_no_question(backend):
    asker = FormAsker()
    callback = _answering(None)
    with _asking(asker):
        out = _mcp({"action": "enable", "connectors": [_mcp_target("paper")]}, callback, mcp_backend=backend)

    assert callback.seen == [] and asker.asked == [] and asker.details == []
    assert ("enable", "paper") in backend.calls
    (target,) = out["targets"]
    assert target["state"] == TargetState.connected.value
    assert out["status"] == "settled" and out["note"].startswith("Turned on for this bot")
    assert live.current("s1") is None


def test_a_connector_that_is_not_installed_asks_the_form_once_with_the_install_option_first(backend):
    asker = FormAsker()
    callback = _answering(None)
    with _asking(asker):
        _mcp({"action": "install", "connectors": [_linear()]}, callback, mcp_backend=backend)

    (questions,) = asker.asked
    (question,) = questions
    assert question["question"] == "Install Linear for this bot?"
    assert question["choices"] == ["Install and set up (Recommended)", "Not now"]
    assert question["choices_offered"] == ["Install and set up", "Not now"]
    assert question["multi_select"] is False
    (details,) = asker.details
    assert "Linear" in details and "https://mcp.linear.app/mcp" in details and "LINEAR_API_KEY" not in details
    assert "a Linear API key" in details
    shown = " ".join([question["question"], *question["choices"], details]).casefold()
    assert not any(word in shown for word in _BANNED)


def test_picking_install_starts_the_existing_install_and_the_card_only_reports_it(backend):
    callback = _answering(None)
    with _asking(FormAsker()), patch("tools.connectors.operation.OPERATION_DEADLINE_SECONDS", 0.3):
        out = _mcp({"action": "install", "connectors": [_linear()]}, callback, mcp_backend=backend)

    assert ("install", "linear", {}) in backend.calls
    (offered,) = callback.seen[0]["targets"]
    assert offered["state"] in (TargetState.initiated.value, TargetState.connected.value)
    assert out["targets"][0]["state"] == TargetState.connected.value


@pytest.mark.parametrize("pick", ["Not now", "Maybe later, ask Bob first", None])
def test_not_now_or_another_answer_settles_declined_and_installs_nothing(backend, pick):
    callback = _answering(None)
    with _asking(FormAsker(pick=pick)):
        out = _mcp({"action": "install", "connectors": [_linear()]}, callback, mcp_backend=backend)

    assert not any(call[0] == "install" for call in backend.calls)
    assert callback.seen == []
    (target,) = out["targets"]
    assert target["state"] == TargetState.declined.value
    assert "do not offer or retry it in this turn" in target["detail"]
    assert out["settled_by"] == SettleReason.all_resolved.value
    assert "declined" in out["note"]


def test_an_unanswered_form_declines_without_installing(backend):
    with _asking(FormAsker(outcome="timed_out")):
        out = _mcp({"action": "install", "connectors": [_linear()]}, _answering(None), mcp_backend=backend)

    assert not any(call[0] == "install" for call in backend.calls)
    assert out["targets"][0]["state"] == TargetState.declined.value


def test_one_form_answers_each_connector_of_a_call_on_its_own(backend):
    class Picky(FormAsker):
        def __call__(self, questions):
            self.asked.append(questions)
            return {"answers": {"q0": "Install and set up (Recommended)", "q1": "Not now"}, "outcome": "submitted"}

    asker = Picky()
    with _asking(asker), patch("tools.connectors.operation.OPERATION_DEADLINE_SECONDS", 0.3):
        out = _mcp({"action": "install", "connectors": [_mcp_target("figma"), _mcp_target("notion")]},
                   _answering(None), mcp_backend=backend)

    assert len(asker.asked) == 1 and len(asker.asked[0]) == 2
    states = {t["name"]: t["state"] for t in out["targets"]}
    assert states == {"figma": TargetState.connected.value, "notion": TargetState.declined.value}
    assert [c for c in backend.calls if c[0] == "install"] == [("install", "figma", {})]


def test_an_unattended_run_settles_not_installed_with_a_reason_and_never_installs(backend):
    callback = _answering(None)
    out = _mcp({"action": "install", "connectors": [_linear()]}, callback, mcp_backend=backend)

    assert not any(call[0] == "install" for call in backend.calls)
    assert callback.seen == [] and live.current("s1") is None
    (target,) = out["targets"]
    assert target["state"] == TargetState.failed.value
    assert target["detail"].startswith("Not installed:") and "no one to ask" in target["detail"]


def test_a_run_nobody_can_answer_never_asks_even_when_a_form_is_bound(backend):
    asker = FormAsker()
    with patch("tools.approval_context._no_user_can_answer", return_value=True), _asking(asker):
        out = _mcp({"action": "install", "connectors": [_linear()]}, _answering(None), mcp_backend=backend)

    assert asker.asked == []
    assert not any(call[0] == "install" for call in backend.calls)
    assert out["targets"][0]["state"] == TargetState.failed.value


def test_no_card_surface_installs_only_after_the_form_picks_install(backend):
    with _asking(FormAsker()):
        out = _off_desktop({"action": "install", "connectors": [_linear()]}, mcp_backend=backend)
    assert ("install", "linear", {}) in backend.calls
    assert out["targets"][0]["state"] == TargetState.connected.value

    declined = FakeBackend()
    with _asking(FormAsker(pick="Not now")):
        out = _off_desktop({"action": "install", "connectors": [_linear()]}, mcp_backend=declined)
    assert declined.calls == []
    assert out["targets"][0]["state"] == TargetState.declined.value


def test_the_card_no_longer_takes_an_allow_or_a_skip_for_an_mcp_row():
    from tools.connectors import mcp
    from tools.connectors.operation import ConnectionOperation, IllegalTransition, Target

    for state in (TargetState.pending, TargetState.initiated):
        operation = ConnectionOperation([Target("paper", "mcp", "install")], session_key="s1")
        mcp._RUNNERS[operation.op_id] = mcp.open_runner("install", FakeBackend())
        try:
            if state == TargetState.initiated:
                operation.transition("paper", TargetState.initiated, mcp.Actor.backend_watcher)
            with pytest.raises(IllegalTransition):
                apply_answer(operation, json.dumps({"targets": [{"name": "paper", "status": "skipped"}]}))
            apply_answer(operation, json.dumps({"targets": [{"name": "paper", "status": "approved"}]}))
            assert operation.target("paper").state == state
        finally:
            mcp._RUNNERS.pop(operation.op_id, None)


def test_the_credential_answer_is_idempotent_and_installs_once():
    backend = FakeBackend(missing_env=["LINEAR_API_KEY"])
    answer = json.dumps({"targets": [{"name": "linear", "status": "approved", "env": {"LINEAR_API_KEY": "k"}}]})
    seen = []

    def callback(payload):
        seen.append(payload)

        def respond():
            operation = live.get("s1", payload["op_id"])
            apply_answer(operation, answer)
            apply_answer(operation, answer)

        threading.Timer(0.01, respond).start()

    with _asking(FormAsker()), patch("tools.connectors.operation.OPERATION_DEADLINE_SECONDS", 0.5):
        out = _mcp({"action": "install", "connectors": [_linear()]}, callback, mcp_backend=backend)

    assert [c for c in backend.calls if c[0] == "install"] == [("install", "linear", {"LINEAR_API_KEY": "k"})]
    assert out["targets"][0]["state"] == TargetState.connected.value


def test_no_connector_prompt_or_tool_text_offers_allow_or_deny(backend):
    from tools.connectors.tool import MANAGE_CONNECTIONS_SCHEMA

    asker = FormAsker(pick="Not now")
    with _asking(asker):
        _mcp({"action": "install", "connectors": [_linear()]}, _answering(None), mcp_backend=backend)
    prompts = [json.dumps(q) for qs in asker.asked for q in qs] + asker.details
    prompts.append(MANAGE_CONNECTIONS_SCHEMA["description"])
    for text in prompts:
        assert not any(word in text.casefold() for word in _BANNED), text


# ---------------------------------------------------------------------------
# off the desktop: no card, so the work runs at once
# ---------------------------------------------------------------------------


def _off_desktop(args, **kw):
    return json.loads(manage_connections(args, session_id="s1", **kw))


def test_off_desktop_authorize_returns_the_link_at_once_and_opens_no_operation(backend):
    out = _off_desktop({"action": "authorize", "connectors": [_mcp_target("paper")]}, mcp_backend=backend)

    (target,) = out["targets"]
    assert target["state"] == TargetState.initiated.value
    assert target["connect_url"] == "https://auth.example/paper/1"
    assert out["status"] == "initiated"
    assert live.current("s1") is None


def test_registry_dispatch_never_blocks_and_never_reaches_a_card(backend):
    # registry.dispatch forwards no callback; the call must return, not block.
    out = json.loads(registry.dispatch("manage_connections", {"action": "enable", "connectors": [_linear()]}))
    assert out["targets"][0]["state"] == TargetState.connected.value


def test_a_managed_action_never_accepts_mcp_targets_and_vice_versa():
    client = FakeClient()
    out = json.loads(manage_connections(
        {"action": "connect", "connectors": ["gmail", _linear()]}, client_factory=lambda: client))
    assert "managed-connector action" in out["error"]
    assert client.calls == []  # rejected before any gateway call

    out = json.loads(manage_connections({"action": "install", "connectors": ["gmail", _linear()]}))
    assert "must carry" in out["error"]




def test_unknown_target_fields_are_rejected():
    out = json.loads(manage_connections({"action": "install", "connectors": [_linear(url="https://evil")]}))
    assert "unknown target field" in out["error"] and "url" in out["error"]


# ---------------------------------------------------------------------------
# catalog validation
# ---------------------------------------------------------------------------


def test_install_is_catalog_only_and_lists_the_catalog_on_a_miss():
    out = json.loads(manage_connections({"action": "install", "connectors": [{"name": "github", "mcp": True}]}))
    assert "github" in out["error"]
    assert "figma, linear, notion" in out["error"]


def test_enable_and_authorize_need_a_configured_server():
    out = json.loads(manage_connections({"action": "enable", "connectors": [{"name": "figma", "mcp": True}]}))
    assert "figma" in out["error"] and "paper" in out["error"]


# ---------------------------------------------------------------------------
# the inline executor + replay shim
# ---------------------------------------------------------------------------


def _agent(callback):
    return SimpleNamespace(session_id="s1", connection_callback=callback)


def test_inline_executor_hands_the_agent_callback_to_the_tool(backend):
    from agent.inline_tool_executors import INLINE_TOOL_EXECUTORS, InlineToolContext

    callback = _answering(json.dumps({"targets": [{"name": "paper", "status": "connected"}], "settled_by": "continue"}))
    with patch("tools.connectors.run.WATCH_INTERVAL_SECONDS", 0.01):
        out = json.loads(INLINE_TOOL_EXECUTORS["manage_connections"](
            _agent(callback), {"action": "authorize", "connectors": [_mcp_target("paper")]}, InlineToolContext("task")))
    assert len(callback.seen) == 1
    assert out["targets"][0]["state"] == TargetState.not_connected.value


def test_setup_mcp_replay_shim_translates_to_an_mcp_target(backend):
    from agent.inline_tool_executors import INLINE_TOOL_EXECUTORS, InlineToolContext

    callback = _answering(json.dumps({"targets": [{"name": "linear", "status": "approved",
                                                  "env": {"LINEAR_API_KEY": "k"}}]}))
    backend.missing_env = ["LINEAR_API_KEY"]
    with patch("tools.connectors.run.WATCH_INTERVAL_SECONDS", 0.01), _asking(FormAsker()):
        out = json.loads(INLINE_TOOL_EXECUTORS["setup_mcp"](
            _agent(callback), {"server": "linear", "action": "install", "reason": "old convo"}, InlineToolContext("task", tool_call_id="call-9")))
    (target,) = callback.seen[0]["targets"]
    assert (target["name"], target["kind"], target["action"], target["state"]) == ("linear", "mcp", "install", "pending")
    assert callback.seen[0]["tool_call_id"] == "call-9"
    assert out["targets"][0]["state"] == TargetState.connected.value


# ---------------------------------------------------------------------------
# deadline ownership
# ---------------------------------------------------------------------------




# ---------------------------------------------------------------------------
# the surface, the actor of a repeated failure, the settle race, the worker guards
# ---------------------------------------------------------------------------


def test_a_desktop_session_with_no_callback_gets_the_link_at_once_and_opens_no_operation(backend):
    """A call that arrives without the callback (registry dispatch, say from execute_code) has
    nothing to render a card, so an operation would block the tool for its whole deadline with
    nobody to answer it. The link goes to the model instead, the way it does off the desktop."""
    with patch("tools.connectors.operation.OPERATION_DEADLINE_SECONDS", 0.2), \
         patch("tools.connectors.run.WATCH_INTERVAL_SECONDS", 0.01):
        out = json.loads(manage_connections({"action": "authorize", "connectors": [_mcp_target("paper")]},
                                            connection_callback=None, session_id="s1", mcp_backend=backend))

    assert out["status"] == "initiated"
    assert out["targets"][0]["connect_url"] == "https://auth.example/paper/1"
    assert live.current("s1") is None


# ---------------------------------------------------------------------------
# late-attempt parking is scoped by (profile, session), never by session alone
# ---------------------------------------------------------------------------


@contextlib.contextmanager
def _as_home(home):
    """Bind a profile home the way the multiplex gateway binds one per activity."""
    from hermes_constants import reset_hermes_home_override, set_hermes_home_override

    token = set_hermes_home_override(str(home))
    try:
        yield
    finally:
        reset_hermes_home_override(token)


def _profile_home(tmp_path, name):
    """A real profile dir with the same-named MCP server configured, as both multiplexed
    homes carry in production."""
    home = tmp_path / name
    home.mkdir(parents=True)
    (home / "config.yaml").write_text(
        "mcp_servers:\n  linear:\n    url: https://mcp.linear.app/mcp\n")
    return home


def _park_attempt(home, name="linear", session_key="s1", profile_key="stamped"):
    """Close a runner whose operation parked one approved OAuth attempt, the way
    ``_Runner.close`` does at the end of a tool call bound to ``home``."""
    from tools.connectors import mcp
    from hermes_constants import hermes_home_key
    from tools.connectors.operation import ConnectionOperation

    attempt = FakeAttempt("https://auth.example/linear")
    attempt.approve(["read"])
    operation = ConnectionOperation(targets=[], session_key=session_key)
    runner = mcp._Runner("authorize", backend=None)
    runner.operation = operation
    runner.op_id = None
    runner.work = {name: mcp._Work(attempt=attempt)}
    with _as_home(home):
        if profile_key == "stamped":
            operation.profile_key = hermes_home_key()  # what live.open stamps
        else:
            operation.profile_key = profile_key  # "" on the detached no-card path
        runner.close()
    return attempt


def _adopt_as(home, agent=None, session_id="s1"):
    """adopt_late_connections as it runs inside a turn bound to ``home``."""
    from tools.connectors import mcp

    registered = []
    agent = agent or SimpleNamespace(session_id=session_id, enabled_toolsets=[])
    with _as_home(home), \
         patch("tools.mcp_tool_discovery.register_mcp_servers",
               side_effect=lambda servers: registered.extend(servers) or list(servers)):
        adopted = mcp.adopt_late_connections(agent)
    return adopted, registered, agent


@pytest.fixture(autouse=True)
def _clear_late_attempts():
    from tools.connectors import mcp

    mcp._LATE_ATTEMPTS.clear()
    yield
    mcp._LATE_ATTEMPTS.clear()


def test_late_attempt_is_never_adopted_by_another_profile(tmp_path):
    """Two multiplexed profiles can carry the same session key (the api_server's
    X-Hermes-Session-Key header is client-chosen, and live.py keys _open by
    (profile, session) for exactly this reason). A parked grant must not leak."""
    from tools.connectors import mcp

    home_a = _profile_home(tmp_path, "home-a")
    home_b = _profile_home(tmp_path, "home-b")
    _park_attempt(home_a)

    adopted, registered, agent = _adopt_as(home_b)
    assert adopted == [] and registered == []
    assert mcp._LATE_ATTEMPTS  # still parked for its owner

    adopted, registered, agent = _adopt_as(home_a)
    assert adopted == ["linear"] and registered == ["linear"]
    assert agent.enabled_toolsets == ["linear"]
    assert mcp._LATE_ATTEMPTS == {}


def test_late_attempt_keyed_by_detached_path_uses_calling_profile(tmp_path):
    """The no-card DetachedOperation never passes through live.open, so profile_key is empty;
    the park must still record the home the tool thread was scoped to."""
    from tools.connectors import mcp

    home_a = _profile_home(tmp_path, "home-a")
    home_b = _profile_home(tmp_path, "home-b")
    _park_attempt(home_a, profile_key="")

    from hermes_constants import hermes_home_key
    with _as_home(home_a):
        assert list(mcp._LATE_ATTEMPTS) == [(hermes_home_key(), "s1")]
    adopted, _registered, _ = _adopt_as(home_b)
    assert adopted == []
    adopted, _registered, _ = _adopt_as(home_a)
    assert adopted == ["linear"]


def test_e2e_carded_oauth_park_and_adopt_stay_inside_their_profile(tmp_path):
    """The production path end to end: an authorize card bound to home A deadline-settles
    while its OAuth attempt is still pending, so _Runner.close parks the attempt under the
    profile key live.open stamped. The browser-side approval that lands afterwards may only
    be adopted by a turn bound to the same home — never by the other multiplexed profile,
    even one that configures the same-named server."""
    from tools.connectors import mcp

    home_a = _profile_home(tmp_path, "home-a")
    home_b = _profile_home(tmp_path, "home-b")

    backend = FakeBackend()
    with _as_home(home_a):
        with patch("tools.connectors.operation.OPERATION_DEADLINE_SECONDS", 0.05):
            out = _mcp({"action": "authorize", "connectors": [_linear()]},
                       _answering(None), mcp_backend=backend)
    assert out["settled_by"] == SettleReason.deadline.value
    backend.attempts["linear"].approve(["read"])  # the browser flow lands after the card closed

    registered = []
    with patch("tools.mcp_tool_discovery.register_mcp_servers",
               side_effect=lambda servers: registered.extend(servers) or list(servers)):
        agent_b = SimpleNamespace(session_id="s1", enabled_toolsets=[])
        with _as_home(home_b):
            assert mcp.adopt_late_connections(agent_b) == []
        assert registered == [] and agent_b.enabled_toolsets == []
        assert mcp._LATE_ATTEMPTS  # still parked for its owner

        agent_a = SimpleNamespace(session_id="s1", enabled_toolsets=[])
        with _as_home(home_a):
            assert mcp.adopt_late_connections(agent_a) == ["linear"]
        assert registered == ["linear"] and agent_a.enabled_toolsets == ["linear"]
        assert mcp._LATE_ATTEMPTS == {}
