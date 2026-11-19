"""The clarify tool's whole question batch for a classic-CLI viewer's turn, in one request.

Main's HermesCLI answered ``clarify_callback(questions)`` with its batch panel: every question shown
at once, one active, answers revisitable until all are locked, ``{answers: {qid: raw | None},
outcome}``. The messaging path asks one card per question. For a classic-CLI local viewer the owner
sends the batch as the existing ``clarify`` server→client request (``ClarifyRequestParams`` →
``ClarifyResult``) through the same request/response machinery as the sudo prompt, so main's own panel
answers it unchanged, and blocks until it answers, the turn is interrupted, or the clarify timeout
(the same config both sides read) passes.
"""
from __future__ import annotations

import uuid

_QUESTION_KEYS = ("qid", "question", "choices", "multi_select")


def batch_answerable(turn) -> bool:
    """Whether the batch request can go out: a viewer is attached, and every attached WebSocket client
    advertised answering server→client requests (``client.capabilities``), or only one is attached (the
    submitter). A client that never advertised (an older app) would reject the request and cancel it for
    everyone, and with no viewer the batch fails at once; either way the per-question cards, which every
    client answers and which wait and push, are asked instead."""
    owner = getattr(turn, "_approval_owner", None)
    if owner is None:
        return False
    authority, session_id, _generation = owner
    live = authority.sessions.get(session_id)
    if live is None:
        return False
    transports = live.event_stream.fanout.transports()
    if not transports:
        return False
    from tui_gateway import server_requests
    from tui_gateway.ws import WSTransport
    clients = [peer for peer in transports if isinstance(peer, WSTransport)]
    return len(clients) <= 1 or all(server_requests.answers_requests(peer) for peer in clients)


def ask_clarify_batch(turn, questions) -> dict:
    from gateway.session_server_requests import ask_viewer_result
    from tools.clarify_gateway import get_clarify_timeout
    authority, session_id, _generation = turn._approval_owner
    live = authority.sessions.get(session_id)
    agent = (getattr(turn._ctx, "agent_holder", None) or [None])[0]
    interrupted = (lambda: bool(getattr(agent, "_interrupt_requested", False))) if agent is not None else (
        lambda: False)
    if live is None:
        return {"answers": {}, "outcome": "cancelled"}
    from gateway.push_notify import Kind, waiting_on_user
    waiting_on_user(authority, session_id, uuid.uuid4().hex[:10], Kind.CLARIFY)
    wire = [{key: entry.get(key) for key in _QUESTION_KEYS if entry.get(key) is not None} for entry in questions]
    timeout = get_clarify_timeout()
    # ``qids``: the viewer's batch panel locks each answer with ``clarify.lock`` (#140400).
    result = ask_viewer_result(live.event_stream, session_id, "clarify", {"questions": wire},
                               cancelled=interrupted, timeout=timeout if timeout > 0 else None,
                               qids=[entry["qid"] for entry in questions])
    if result is None:
        return {"answers": {}, "outcome": "cancelled" if interrupted() else "timed_out"}
    answers = result.get("answers")
    if not isinstance(answers, dict):
        return {"answers": {}, "outcome": "cancelled"}
    known = {entry["qid"] for entry in questions}
    clean = {qid: (value if isinstance(value, str) else None) for qid, value in answers.items() if qid in known}
    # ``session_server_requests`` settles a batch with its terminal outcome (an absent outcome on a frame
    # that carried answers is ``submitted``; a cancel-all or error is ``cancelled``).
    outcome = result.get("outcome") if result.get("outcome") in ("submitted", "timed_out", "cancelled") else "cancelled"
    return {"answers": clean, "outcome": outcome}
