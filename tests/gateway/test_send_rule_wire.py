"""The gateway wire of "always allow": the card's choices, the ``always`` answer, and the list and revoke verbs."""

import threading

import pytest
import pytest_asyncio

from gateway.session_pending_controls import PendingControls
from hermes_cli.profiles import get_profile_dir
from tests.gateway.bots_harness import FULL, READ, bots_state, call, failure, install_state
from tools import send_rules
from tools.approval import _gateway_queues
from tools.approval_gateway_wait import _ApprovalEntry
from tui_gateway import server
from tui_gateway.contracts.registry import CANONICAL_METHODS, METHODS
from tui_gateway.contracts.server_requests import ApprovalResult

install = pytest.fixture(install_state)
bots = pytest_asyncio.fixture(bots_state)

OFFERED = ["once", "always", "deny"]
PLAIN = ["once", "deny"]
SESSION_KEY, SID, REQUEST_ID = "20261127_120000_cccccc", "live-send-rules", "req-rule-1"
CHOICES = [(OFFERED, OFFERED), (PLAIN, PLAIN), (["once", "session", "always", "deny"], PLAIN), (None, PLAIN)]


@pytest.mark.parametrize("raised,shown", CHOICES)
def test_every_surface_shows_always_only_for_a_card_that_offers_it(raised, shown):
    published = []

    class Events:
        lock = threading.RLock()

        def publish(self, session_id, payload, event_type):
            published.append(payload)

    data = {"request_id": REQUEST_ID, "description": "Send", **({} if raised is None else {"choices": raised})}
    PendingControls(Events()).register("sid", "route", 1, data)
    assert published[0]["choices"] == shown
    assert server._approval_request_payload(data)["choices"] == shown


def test_the_server_request_answer_accepts_always():
    assert ApprovalResult.model_validate({"choice": "always"}).choice == "always"


@pytest.fixture()
def pending():
    server._sessions[SID] = {"_sid": SID, "session_key": SESSION_KEY, "history": [],
                             "history_lock": threading.Lock(), "running": False, "agent": None}

    def enqueue(choices):
        entry = _ApprovalEntry({"description": "Send", "request_id": REQUEST_ID, "choices": choices})
        _gateway_queues.setdefault(SESSION_KEY, []).append(entry)
        return entry

    yield enqueue
    _gateway_queues.pop(SESSION_KEY, None)
    server._sessions.pop(SID, None)


def _respond(**params):
    return server.handle_request(
        {"id": "r", "method": "approval.respond", "params": {"session_id": SID, **params}})


def test_approval_respond_takes_always_for_the_named_card_that_offers_it(pending):
    entry = pending(OFFERED)
    assert _respond(choice="always", request_id=REQUEST_ID)["result"]["resolved"] == 1
    assert (entry.result, entry.remember) == ("once", True)


@pytest.mark.parametrize("choices,params", [
    (PLAIN, {"request_id": REQUEST_ID}),
    (OFFERED, {}),
    (OFFERED, {"request_id": REQUEST_ID, "all": True}),
    (OFFERED, {"request_id": "someone-else"}),
], ids=["not-offered", "no-request-id", "all", "unknown-card"])
def test_approval_respond_refuses_any_other_always_and_leaves_the_card_pending(pending, choices, params):
    entry = pending(choices)
    assert _respond(choice="always", **params)["error"]["code"] == 4133
    assert entry.result is None and not entry.remember


def _remember_in(monkeypatch, root, home, label):
    monkeypatch.setenv("HERMES_HOME", str(home))
    send_rules.remember(send_rules.SendRuleCandidate("send_message", label, label, f"Send to {label}"))
    monkeypatch.setenv("HERMES_HOME", str(root))


@pytest.mark.asyncio
async def test_the_verbs_list_and_revoke_only_the_caller_bots_rules(bots, monkeypatch):
    _remember_in(monkeypatch, bots.root, get_profile_dir("alpha"), "#alpha")
    _remember_in(monkeypatch, bots.root, get_profile_dir("beta"), "#beta")
    alpha, beta = bots.connect("alpha"), bots.connect("beta")

    listed = (await call(alpha, "approval.rules.list", {}))["result"]
    CANONICAL_METHODS["approval.rules.list"].result.model_validate(listed)
    [row] = listed["rules"]
    assert set(row) == {"id", "tool", "destination_label", "created_at", "last_used_at", "uses"}
    assert (row["destination_label"], row["uses"], row["last_used_at"]) == ("#alpha", 0, None)

    assert (await call(beta, "approval.rules.revoke", {"id": row["id"]}))["result"] == {"ok": False}
    assert failure(await call(beta, "approval.rules.list", {"profile": "alpha"}))["message"] == "profile_mismatch"
    reader = bots.connect("alpha", capabilities=READ)
    assert failure(await call(reader, "approval.rules.revoke", {"id": row["id"]}))["message"] == "permission_denied"
    assert (await call(reader, "approval.rules.list", {}))["result"] == listed

    assert (await call(alpha, "approval.rules.revoke", {"id": row["id"]}))["result"] == {"ok": True}
    assert (await call(alpha, "approval.rules.list", {}))["result"] == {"rules": []}
    [kept] = (await call(beta, "approval.rules.list", {}))["result"]["rules"]
    assert kept["destination_label"] == "#beta"


@pytest.mark.asyncio
async def test_the_apps_shared_socket_names_the_bot(bots, monkeypatch):
    _remember_in(monkeypatch, bots.root, get_profile_dir("alpha"), "#alpha")
    app = bots.connect(host=True, capabilities=FULL)
    [row] = (await call(app, "approval.rules.list", {"profile": "alpha"}))["result"]["rules"]
    assert (await call(app, "approval.rules.list", {}))["result"] == {"rules": []}
    revoked = await call(app, "approval.rules.revoke", {"profile": "alpha", "id": row["id"]})
    assert revoked["result"] == {"ok": True}


def test_no_verb_creates_a_rule():
    verbs = {name for name in (*METHODS, *CANONICAL_METHODS) if name.startswith("approval.rules.")}
    assert verbs == {"approval.rules.list", "approval.rules.revoke"}
