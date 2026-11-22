from __future__ import annotations

import re
import sys

import pytest

from tests.e2e.core.platforms import _contract as C
from tests.e2e.core.platforms import _member_rig as M
from tests.fakes.platforms._standin import wait_until

pytestmark = [
    pytest.mark.spawns_gateway_lookalike,
    pytest.mark.skipif(sys.platform == "win32", reason="POSIX process-group gateway harness"),
]

CHANNEL = "C0000CHN"


def world_fixture(label: str, audience, extra_cfg=None):
    @pytest.fixture(scope="module")
    def build(tmp_path_factory):
        built = M.make_world(tmp_path_factory, label, audience=audience, extra_cfg=extra_cfg)
        yield built
        try:
            print(f"\nartifact: {M.write_artifact(built, f'slack-member-{label}.json')}")
        finally:
            M.teardown(built)
    return build


listed = world_fixture("listed", {"policy": "listed", "members": [M.ALICE]})
limited = world_fixture("rate", {"policy": "workspace", "member_turns_per_hour": 2})
queued = world_fixture("busy", {"policy": "workspace", "member_turns_per_hour": 2},
                       {"display": {"busy_input_mode": "queue"}})


def test_only_listed_people_are_served_and_unlisted_context_is_marked_unverified(listed):
    M.post(listed, M.BOB, CHANNEL, "unlisted colleague [in:bob]")
    M.assert_no_turn(listed, "bob")

    root = M.post(listed, M.BOB, CHANNEL, "bob's remark in a thread", mention=False)
    M.post(listed, M.ALICE, CHANNEL, "alice's remark", mention=False, thread_ts=root)
    listed.settle()
    aid = M.scripted(listed, "tags")
    M.post(listed, M.OWNER, CHANNEL, "summarise [in:tags]", thread_ts=root)
    C.wait_reply(listed, CHANNEL, aid)
    context = "\n".join(str(m.get("content")) for m in listed.request("tags", 0)["messages"] if m.get("role") == "user")
    assert re.search(r"\[unverified\] \S*useru0000bbb: bob's remark in a thread", context), context
    assert re.search(r"\[member\] \S*useru0000aaa: alice's remark", context), context

    served = M.scripted(listed, "alice")
    M.post(listed, M.ALICE, CHANNEL, "listed member [in:alice]")
    C.wait_reply(listed, CHANNEL, served)
    (key, _), = listed.sessions_of("[in:alice]")
    assert key.endswith(":~member")


def test_member_turns_beyond_the_hourly_budget_get_one_notice_then_silence(limited):
    for n in (1, 2):
        aid = M.scripted(limited, f"budget{n}")
        M.post(limited, M.ALICE, CHANNEL, f"question {n} [in:budget{n}]")
        C.wait_reply(limited, CHANNEL, aid)

    def notices() -> list:
        return [v for v in limited.drv.visible(CHANNEL) if M.RATE_NOTICE in C.norm(v.text)]

    M.post(limited, M.ALICE, CHANNEL, "question 3 [in:budget3]")
    wait_until(notices, "the single over-budget notice", timeout=C.TURN_TIMEOUT, on_timeout=limited.ctx)
    M.post(limited, M.ALICE, CHANNEL, "question 4 [in:budget4]")
    M.assert_no_turn(limited, "budget3")
    assert C.turns(limited, "budget4") == 0
    assert len(notices()) == 1, notices()


def test_a_member_message_sent_mid_turn_is_queued_and_charged_once(queued):
    slow = C.answer("A-busy1", "slow answer " * 12)
    slow.delay_per_chunk = 0.25
    queued.director.script("busy1", slow)
    root = M.post(queued, M.ALICE, CHANNEL, "first question [in:busy1]")
    wait_until(lambda: C.turns(queued, "busy1") >= 1, "the first member turn to start", timeout=C.TURN_TIMEOUT,
               on_timeout=queued.ctx)
    aid2 = M.scripted(queued, "busy2")
    M.post(queued, M.ALICE, CHANNEL, "second question [in:busy2]", thread_ts=root)
    C.wait_reply(queued, CHANNEL, "A-busy1", "the first answer")
    C.wait_reply(queued, CHANNEL, aid2, "the queued member message served after the first turn")
    assert not [v for v in queued.drv.visible(CHANNEL) if M.RATE_NOTICE in C.norm(v.text)]
    M.post(queued, M.ALICE, CHANNEL, "third question [in:busy3]", thread_ts=root)
    wait_until(lambda: [v for v in queued.drv.visible(CHANNEL) if M.RATE_NOTICE in C.norm(v.text)],
               "the over-budget notice only after two charged turns", timeout=C.TURN_TIMEOUT, on_timeout=queued.ctx)
