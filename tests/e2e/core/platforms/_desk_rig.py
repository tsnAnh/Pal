from __future__ import annotations

import json
import sqlite3
from pathlib import Path
from typing import Any, Optional

from tests.e2e.core.platforms import _contract as C
from tests.e2e.core.platforms import _member_rig as M
from tests.fakes.fake_llm_provider import ToolCall
from tests.fakes.platforms._standin import wait_until
from tests.fakes.platforms.slack_standin import TEAM_ID

OWNER_DM = f"D{M.OWNER[1:]}"
CAROL, DAVE, ERIN, FRANK, GINA, HANK = ("U0000CCC", "U0000DDD", "U0000EEE", "U0000FFF", "U0000GGH", "U0000HHH")
APPROVE, DECLINE = "hermes_desk_approve", "hermes_desk_decline"
EXEC_APPROVE, EXEC_DENY = "hermes_approve_once", "hermes_deny"
AMBIGUOUS_NOTICE = "Which question is this for? Please reply directly under the message you are answering."
DESK_WAIT = 60.0


def seed_slack_install(hermes_home: Path, token: str) -> None:
    from agent.vault_store import VaultStore
    from gateway.chat_install_store import ChatInstallStore
    from gateway.chat_slack.records import SlackRecords
    from tui_gateway.contracts.chat_provider import Installation, InstallationStatus
    item = VaultStore(hermes_home / "vault").add_item("api_key", "Slack bot token", {"api_key": token}).id
    installation = Installation(
        id="inst-desk", provider_id="slack", bot="default", workspace_id="w1", workspace_name="Standin",
        status=InstallationStatus.active, created_at=0.0, updated_at=0.0, vault_item_ids=[item])
    ChatInstallStore(hermes_home).save_installation(installation, [], M.OWNER)
    SlackRecords(hermes_home / "chat_slack" / "records.json").update_app(
        "default", "w1", installation_id="inst-desk", bot_token_item_id=item, team_id=TEAM_ID, team_name="Standin")


def make_desk_world(factory, label: str, *, audience: Optional[dict] = None, free_channels: tuple = (),
                    extra_cfg: Optional[dict] = None) -> M.World:
    return M.make_world(factory, label, audience=audience, free_channels=free_channels, extra_cfg=extra_cfg,
                        prepare=lambda gw, drv: seed_slack_install(gw.hermes_home, drv.standin.bot_token))


def _rows(world: M.World) -> list[sqlite3.Row]:
    path = world.gw.hermes_home / "desk.db"
    if not path.exists():
        return []
    conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=30)
    conn.row_factory = sqlite3.Row
    try:
        return conn.execute("SELECT * FROM items ORDER BY created_at, id").fetchall()
    finally:
        conn.close()


def desk_rows(world: M.World) -> list[dict[str, Any]]:
    return [{**dict(row), "payload": json.loads(row["payload_json"]),
             "outcome": json.loads(row["outcome_json"]) if row["outcome_json"] else None,
             "origin": json.loads(row["origin_json"])} for row in _rows(world)]


def desk_edit(world: M.World, sql: str, *args: Any) -> None:
    conn = sqlite3.connect(world.gw.hermes_home / "desk.db", timeout=30)
    try:
        with conn:
            conn.execute(sql, args)
    finally:
        conn.close()


def wait_row(world: M.World, what: str, predicate, timeout: float = DESK_WAIT) -> dict[str, Any]:
    found: list[dict[str, Any]] = []

    def check() -> bool:
        found[:] = [row for row in desk_rows(world) if predicate(row)]
        return bool(found)
    wait_until(check, what, timeout=timeout, on_timeout=world.ctx)
    return found[0]


def slack_posts(world: M.World, channel: str) -> list[Any]:
    return [c for c in world.drv.standin.calls_of("chat.postMessage") if str(c.params.get("channel")) == channel]


def desk_buttons(world: M.World, channel: str = OWNER_DM) -> list[dict[str, Any]]:
    return [b for b in world.drv.standin.buttons(channel) if str(b.get("action_id", "")).startswith("hermes_desk_")]


def wait_desk_card(world: M.World, channel: str = OWNER_DM, *, count: int = 1) -> list[dict[str, Any]]:
    wait_until(lambda: len(desk_buttons(world, channel)) >= 2 * count, "the owner card buttons",
               timeout=DESK_WAIT, on_timeout=world.ctx)
    return desk_buttons(world, channel)


def exec_buttons(world: M.World, channel: str = OWNER_DM) -> list[dict[str, Any]]:
    return [b for b in world.drv.standin.buttons(channel) if b.get("action_id") in (EXEC_APPROVE, EXEC_DENY)]


def wait_exec_card(world: M.World, channel: str = OWNER_DM) -> tuple[dict[str, Any], dict[str, Any]]:
    wait_until(lambda: len(exec_buttons(world, channel)) >= 2, "the exact-call approval card", timeout=DESK_WAIT,
               on_timeout=world.ctx)
    buttons = exec_buttons(world, channel)
    return card_choice(buttons, EXEC_APPROVE), card_choice(buttons, EXEC_DENY)


def tap_exec(world: M.World, button: dict[str, Any], channel: str = OWNER_DM) -> None:
    click(world, M.OWNER, button, channel)
    wait_until(lambda: not exec_buttons(world, channel), "the approval card closed", timeout=DESK_WAIT,
               on_timeout=world.ctx)


def click(world: M.World, user: str, button: dict[str, Any], channel: str = OWNER_DM) -> dict[str, Any]:
    return world.drv.standin.block_action(user, channel, str(button["message_id"]), button)


def card_choice(buttons: list[dict[str, Any]], action_id: str, message_id: Optional[str] = None) -> dict[str, Any]:
    return next(b for b in buttons if b["action_id"] == action_id and (message_id is None or b["message_id"] == message_id))


def card_text(world: M.World, message_ts: str, channel: str = OWNER_DM) -> str:
    return next((v.text for v in world.drv.visible(channel) if v.message_id == message_ts), "")


def write_artifact_with_rows(world: M.World, name: str) -> Path:
    path = M.write_artifact(world, name)
    payload = json.loads(path.read_text(encoding="utf-8"))
    payload["desk_rows"] = {"default": [{k: v for k, v in row.items() if k not in ("origin_json", "payload_json",
                                                                                     "outcome_json")}
                                        for row in desk_rows(world)]}
    path.write_text(json.dumps(payload, indent=2, sort_keys=True, default=str), encoding="utf-8")
    return path


def owner_says(world: M.World, token: str, text: str, *replies) -> str:
    aid = M.scripted(world, token, *replies)
    M.dm(world, M.OWNER, f"{text} [in:{token}]")
    C.wait_reply(world, OWNER_DM, aid, f"owner turn {token} answered")
    return aid


def ask(person: str, question: str, **extra):
    return ToolCall("slack_send_dm", {"user_id": person, "text": question, "wait_for_reply": True, **extra})


def open_ask_for(world: M.World, person: str, question: Optional[str] = None) -> dict:
    return wait_row(world, f"an open ask for {person}", lambda r: r["kind"] == "ask" and r["state"] == "open"
                      and r["payload"]["target"]["user_id"] == person
                      and (question is None or r["payload"]["question"] == question))


def dm_posts(world: M.World, person: str) -> list[str]:
    return [p.params["text"] for p in slack_posts(world, f"D{person[1:]}")]


def alice_replies(world: M.World, person: str, token: str, text: str = "four point two", **extra) -> str:
    return world.drv.standin.dm(person, f"{text} [in:{token}]", **extra)["payload"]["event"]["ts"]
