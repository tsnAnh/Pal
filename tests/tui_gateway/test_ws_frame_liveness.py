"""Every received frame, the inline ``gateway.ping`` heartbeat included, is liveness evidence for the peer's
reach slot."""
import asyncio
import json

from gateway import reach_presence
from tui_gateway import server
from tui_gateway import ws as ws_mod


def _run(monkeypatch, frames):
    monkeypatch.setattr(server, "_WS_ORPHAN_REAP_GRACE_S", 0)
    created, seen = [], []
    real_transport = ws_mod.WSTransport
    monkeypatch.setattr(
        ws_mod, "WSTransport",
        lambda ws, loop, **kw: created.append(real_transport(ws, loop, **kw)) or created[-1])
    inbound = iter(frames)

    class FakeWS:
        async def accept(self):
            pass

        async def send_text(self, line):
            pass

        async def receive_text(self):
            seen.append(reach_presence.last_frame_at(created[0]))
            try:
                return next(inbound)
            except StopIteration:
                raise ws_mod._WebSocketDisconnect()

        async def close(self):
            pass

    asyncio.run(ws_mod.handle_ws(FakeWS()))
    return created[0], seen


def test_a_ping_only_peer_still_shows_liveness(monkeypatch):
    ping = json.dumps({"jsonrpc": "2.0", "id": "p1", "method": "gateway.ping", "params": {}})
    transport, seen = _run(monkeypatch, [ping])
    assert seen[0] is None
    assert transport.last_frame_at is not None and transport.last_frame_at == reach_presence.last_frame_at(transport)


def test_an_unparseable_frame_is_still_a_sign_of_life(monkeypatch):
    transport, seen = _run(monkeypatch, ["{not json"])
    assert seen[0] is None and transport.last_frame_at is not None


def test_a_peer_that_never_sent_a_frame_has_no_liveness_stamp(monkeypatch):
    transport, seen = _run(monkeypatch, [])
    assert transport.last_frame_at is None and seen == [None]
