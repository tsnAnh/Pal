import json
import time
from pathlib import Path

from gateway import commitments as cm
from gateway import reach_log
from gateway.commitments import Actor, Details, Route, State
from gateway.reach_policy import Verdict
from persistence_assembly import open_persistence, profile_scope
from tests.fixtures.storage_seed import seed_messages, seed_session
from tests.gateway.reach_harness import make_home

SENTINEL = "SENTINEL-7f3a"
NOW = time.time()
HOUR = 60 * 60
DAY = 24 * HOUR
ROUTE = Route(platform="telegram", chat_id="42", chat_type="dm", session_id="s1")
CLOSING = Details(next_step="ping the reviewer", blocker_what="the review", blocker_who="owner",
                  evidence="PR #12 merged", reason="plans changed")
_keys = iter(range(100_000))


def promise(home: Path, *, at: float, owner_requested: bool = False, due_at: float | None = None) -> str:
    return cm.promise(home, event_key=f"fx{next(_keys)}", profile="main", text=f"Ship {SENTINEL}",
                      owner_requested=owner_requested, due_at=due_at, route=ROUTE, now=at).commitment_id


def move(home: Path, commitment_id: str, to: State, *, at: float, actor: Actor = Actor.BOT) -> None:
    current = cm.get(home, commitment_id)
    cm.transition(home, commitment_id, event_key=f"fx{next(_keys)}", expected_rev=current.rev, to=to,
                  details=CLOSING, actor=actor, now=at)


def offer_with_outcome(home: Path, *, at: float, outcome: str | None, domain: str = "commitments") -> None:
    claim = reach_log.claim(home, producer_key=f"fx:{next(_keys)}", domain=domain, kind="notify",
                            consent="initiated", title=f"Done: {SENTINEL}",
                            judge=lambda view: Verdict(True, True, None, ""), now=at)
    reach_log.finalize(home, claim.row["offer_id"], status="alerted", reason="", alerted_at=at)
    if outcome is not None:
        reach_log.record_outcome(home, claim.row["offer_id"], outcome, None, at + 60)


def commitment_call(action: str = "promise") -> dict:
    return {"id": f"c{next(_keys)}", "type": "function",
            "function": {"name": "commitment", "arguments": json.dumps({"action": action, "text": SENTINEL})}}


def seed_conversation(home: Path, session_id: str, *messages: dict) -> None:
    with open_persistence(profile_scope(home=home), eager=True) as writer:
        seed_session(writer, session_id, "telegram")
        seed_messages(writer, session_id, *messages)


def ledger(home: Path) -> None:
    done = promise(home, at=NOW - 5 * DAY, owner_requested=True, due_at=NOW - DAY)
    move(home, done, State.DONE, at=NOW - 2 * DAY)
    promise(home, at=NOW - 4 * DAY, due_at=NOW - 2 * HOUR)
    dropped = promise(home, at=NOW - 3 * DAY)
    move(home, dropped, State.ABANDONED, at=NOW - DAY)
    owner_dropped = promise(home, at=NOW - 3 * DAY, owner_requested=True)
    move(home, owner_dropped, State.ABANDONED, at=NOW - DAY, actor=Actor.OWNER)
    working = promise(home, at=NOW - DAY)
    move(home, working, State.IN_PROGRESS, at=NOW - 12 * HOUR)
    old = promise(home, at=NOW - 20 * DAY, due_at=NOW - 19 * DAY)
    move(home, old, State.DONE, at=NOW - 19 * DAY - HOUR)


def reach_offers(home: Path) -> None:
    offer_with_outcome(home, at=NOW - 2 * DAY, outcome="acted")
    offer_with_outcome(home, at=NOW - DAY, outcome="acted", domain="cron")
    offer_with_outcome(home, at=NOW - DAY, outcome="dismissed")
    offer_with_outcome(home, at=NOW - HOUR, outcome=None)
    offer_with_outcome(home, at=NOW - 20 * DAY, outcome="dismissed")


def conversation(home: Path) -> None:
    seed_conversation(
        home, "s1",
        {"role": "user", "content": f"Please draft the release note {SENTINEL}"},
        {"role": "assistant", "content": "Should I go ahead and draft it?"},
        {"role": "user", "content": "just do it"},
        {"role": "assistant", "content": f"Draft ready: {SENTINEL}. I'll check back tomorrow."},
        {"role": "user", "content": "xong chưa?"},
        {"role": "assistant", "content": "On it.", "tool_calls": [commitment_call()]},
        {"role": "assistant", "content": "I'll follow up when CI is green."})


def bot_home(root: Path, name: str = "bot") -> Path:
    home = make_home(root, name)
    ledger(home)
    reach_offers(home)
    conversation(home)
    return home
