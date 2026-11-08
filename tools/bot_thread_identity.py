from __future__ import annotations

import hashlib
import json
from dataclasses import asdict, dataclass
from enum import StrEnum
from typing import Mapping, Optional, Sequence

from tools.bot_dm_wire import SenderStamp

RELAY_PRINCIPAL_ORIGIN = "relay"


class Lane(StrEnum):
    local = "local"
    relay = "relay"
    peer = "peer"


class Attribution(StrEnum):
    transport = "transport"
    stamp = "stamp"


@dataclass(frozen=True, slots=True)
class CounterpartRef:
    lane: Lane
    origin: str
    profile: str
    handle: str
    display_name: str
    attribution: Attribution = Attribution.transport
    provisional: bool = False

    @property
    def key(self) -> str:
        if self.lane is Lane.local:
            return f"local:{self.profile}"
        if self.provisional:
            return f"peer:{self.origin}/{self.profile}"
        return f"remote:{self.origin}/{self.profile}"

    @property
    def thread_id(self) -> str:
        return thread_id_for(self.key)

    def to_json(self) -> str:
        return json.dumps(asdict(self), sort_keys=True)

    @classmethod
    def from_json(cls, raw: str) -> CounterpartRef:
        data = json.loads(raw)
        return cls(lane=Lane(data["lane"]), origin=data["origin"], profile=data["profile"], handle=data["handle"],
                   display_name=data["display_name"], attribution=Attribution(data["attribution"]),
                   provisional=bool(data.get("provisional")))


def thread_id_for(key: str) -> str:
    return "bt_" + hashlib.blake2b(key.encode("utf-8"), digest_size=10).hexdigest()


def outbound_local(profile: str, handle: str, display_name: str) -> CounterpartRef:
    return CounterpartRef(Lane.local, "", profile, handle, display_name or handle)


def outbound_relay(row: Mapping[str, str]) -> CounterpartRef:
    handle = row["handle"]
    return CounterpartRef(Lane.relay, row["connection_id"], row["profile"], handle, row.get("title") or handle)


def outbound_peer(peer_name: str, profile: Optional[str], learned_origin: Optional[str]) -> CounterpartRef:
    remote_profile = profile or "default"
    handle = profile or "hermes"
    return CounterpartRef(Lane.peer, learned_origin or peer_name, remote_profile, handle, handle,
                          provisional=not learned_origin)


def relearned(ref: CounterpartRef, origin: str) -> CounterpartRef:
    return CounterpartRef(ref.lane, origin, ref.profile, ref.handle, ref.display_name, ref.attribution)


def _stamp_names(stamp: Optional[SenderStamp], fallback: str) -> tuple[str, str]:
    if stamp is None:
        return fallback, fallback
    return stamp.handle, stamp.display_name


def _relay_principal_sender(stamp: Optional[SenderStamp], roster: Sequence[Mapping[str, str]]) -> Optional[CounterpartRef]:
    if stamp is None:
        return None
    handle = stamp.handle.lower()
    matches = [row for row in roster if row["handle"].lower() == handle
               and (stamp.connection is None or row["connection_id"].lower() == stamp.connection.lower())]
    if len(matches) == 1:
        row = matches[0]
        return CounterpartRef(Lane.relay, row["connection_id"], row["profile"], row["handle"],
                              stamp.display_name, Attribution.stamp)
    return CounterpartRef(Lane.relay, RELAY_PRINCIPAL_ORIGIN, stamp.handle, stamp.handle, stamp.display_name,
                          Attribution.stamp)


def inbound(author: Optional[Mapping[str, object]], stamp: Optional[SenderStamp],
            relay_roster: Sequence[Mapping[str, str]]) -> Optional[CounterpartRef]:
    if not isinstance(author, Mapping) or author.get("is_bot") is not True:
        return None
    raw_id = str(author.get("id") or "")
    if not raw_id.startswith("bot:"):
        return None
    origin, _, profile = raw_id[4:].rpartition("/")
    if not profile:
        return None
    handle, display_name = _stamp_names(stamp, str(author.get("name") or profile))
    if not origin:
        return CounterpartRef(Lane.local, "", profile, handle, display_name)
    if origin == RELAY_PRINCIPAL_ORIGIN:
        return _relay_principal_sender(stamp, relay_roster)
    is_relay = any(row["connection_id"] == origin for row in relay_roster)
    return CounterpartRef(Lane.relay if is_relay else Lane.peer, origin, profile, handle, display_name)
