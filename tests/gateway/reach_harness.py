import asyncio
import json
import sqlite3
from pathlib import Path
from types import SimpleNamespace

from gateway import reach
from gateway.config import Platform
from gateway.reach_presence import AttentionState, ClientKind, Device, declare
from gateway.session_cron import bind_owner, unbind_owner
from hermes_state import SessionDB

PROACTIVE_ON = "proactive:\n  enabled: true\n  quiet_hours: null\n  min_gap_minutes: 0\n"


def make_home(root: Path, name: str, config: str = PROACTIVE_ON) -> Path:
    home = root / name
    home.mkdir(parents=True)
    (home / "config.yaml").write_text(config, encoding="utf-8")
    SessionDB(db_path=home / "state.db").close()
    return home


class FakeAppTransport:
    def __init__(self, home: Path, label: str, *, acks: bool = True, accepts: bool = True,
                 attention=AttentionState.FOREGROUND, kind=ClientKind.DESKTOP, last_input: float | None = None):
        self.home, self.acks = home, acks
        self.frames: list[dict] = []
        self.loop = None
        self.device = Device(kind=kind, device_id=f"device-{label}".ljust(12, "0"), label=label, app_version="1.0")
        declare(self, self.device, accepts_offers=accepts, same_host=False, attention=attention)
        if last_input is not None:
            from gateway.reach_presence import record_input
            record_input(self, last_input)

    def write(self, frame: dict) -> bool:
        self.frames.append(frame)
        if self.acks and self.loop is not None:
            offer_id = frame["params"]["payload"]["offer_id"]
            asyncio.run_coroutine_threadsafe(
                reach.record_outcome(self.home, offer_id, reach.Outcome.SHOWN, self.device, transport=self), self.loop)
        return True


class FakeRunner:
    def __init__(self, *, multiplex: bool = False, platforms=None, adapters=None):
        self.config = SimpleNamespace(multiplex_profiles=multiplex, platforms=platforms or {})
        self.adapters = adapters or {}
        self.session_authorities = None
        self.sent: list[tuple[str, str, str]] = []
        self.send_ok = True

    async def _send_home_channel_message(self, platform, home, transport, message, failure_fmt):
        self.sent.append((platform.value, home.chat_id, message))
        return self.send_ok


def telegram_runner(chat_id: str = "555", **kwargs) -> FakeRunner:
    home_channel = SimpleNamespace(chat_id=chat_id, thread_id=None, user_id=None, scope_id=None)
    platforms = {Platform.TELEGRAM: SimpleNamespace(enabled=True, home_channel=home_channel)}
    return FakeRunner(platforms=platforms, adapters={Platform.TELEGRAM: object()}, **kwargs)


def make_authority(home: Path, runner: FakeRunner | None = None) -> SimpleNamespace:
    return SimpleNamespace(db=SimpleNamespace(db_path=str(home / "state.db")), events={}, profile_id=str(home),
                           runner=runner or FakeRunner())


def attach(authority, transport: FakeAppTransport, transport_id: str) -> None:
    transport.loop = asyncio.get_running_loop()
    authority.events[transport_id] = transport


def offer_item(key="cron:job:1", *, consent=reach.Consent.REQUESTED, domain="cron", kind=reach.OfferKind.NOTIFY,
               title="Daily digest", body="Three things changed.", lane=None):
    return reach.Offer(producer_key=key, domain=domain, kind=kind, consent=consent, title=title, body=body, lane=lane)


def run_with_owner(authority, scenario):
    async def main():
        bind_owner(authority)
        try:
            return await scenario()
        finally:
            unbind_owner(authority)
    return asyncio.run(main())


def rows(home: Path) -> list[dict]:
    conn = sqlite3.connect(home / "state.db")
    conn.row_factory = sqlite3.Row
    try:
        return [dict(r) for r in conn.execute("SELECT * FROM reach_offers ORDER BY created_at")]
    finally:
        conn.close()


def attempts(row: dict) -> list[str]:
    return [a["result"] for a in json.loads(row["attempts_json"])]


def add_chat_message(home: Path, platform: str, chat_id: str, *, at: float, role: str = "user") -> None:
    conn = sqlite3.connect(home / "state.db")
    try:
        session_id = f"{platform}-{chat_id}"
        conn.execute("INSERT OR IGNORE INTO sessions (id, source, chat_id, started_at) VALUES (?, ?, ?, ?)",
                     (session_id, platform, chat_id, at))
        conn.execute("INSERT INTO messages (session_id, role, content, timestamp) VALUES (?, ?, 'hi', ?)",
                     (session_id, role, at))
        conn.commit()
    finally:
        conn.close()

