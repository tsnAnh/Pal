"""What Pal drives for a Slack bot that talks to more than its owner: install defaults, who may talk, where reports
go, leaving a channel, the bot's picture and its automatic identity push, and the owner desk. The real RPCs, service
and Slack provider run over the fake Slack transport.
"""

from __future__ import annotations

import base64
import io
import time

import pytest

from PIL import Image

from gateway import chat_identity_sync
from gateway.audience import AudiencePolicy
from gateway.chat_audience import read_audience
from gateway.chat_install_store import ChatInstallStore
from gateway.chat_slack.provider import profile_identity
from gateway.desk.model import ItemState, Origin, Recipient
from gateway.desk.owner import OwnerContact
from gateway.desk.service import Desk
from gateway.desk.store import DeskStore
from hermes_cli.config import read_config_doc
from hermes_cli.profiles import get_profile_dir
from hermes_cli.web_routers import messaging
from tests.gateway.chat_slack.fake_slack import FakeSlack
from tests.gateway.chat_slack.test_slack_install_profiles import BOT, TEAM, Rig
from tests.tui_gateway.contracts.chat_provider_fakes import FIXED_NOW
from tests.waiting import wait_until
from tui_gateway import server
from tui_gateway.desk_feed import DeskFeed
from utils.files import atomic_yaml_write

OWNER = "UOWNER"


@pytest.fixture
def rig(tmp_path, monkeypatch):
    return lambda **options: Rig(tmp_path, monkeypatch, FakeSlack(now=FIXED_NOW, **options))


def _config(profile: str) -> dict:
    path = get_profile_dir(profile) / "config.yaml"
    return dict(read_config_doc(path) or {}) if path.exists() else {}


def _png_url(side: int = 512) -> str:
    out = io.BytesIO()
    Image.new("RGB", (side, side), (20, 120, 220)).save(out, format="PNG")
    return "data:image/png;base64," + base64.b64encode(out.getvalue()).decode()


def _reason(response: dict) -> str:
    return response["error"]["data"]["reason"]


def _desk_rpc(method: str, **params) -> dict:
    return server.handle_request({"id": "1", "method": method, "params": {"profile": BOT, **params}})


def _next_changes(feed: DeskFeed, home) -> list:
    found: list = []
    wait_until(lambda: found.extend(feed.changes([home])) or found, what="a desk change")
    return found


def _wait_idle(bot: str = BOT) -> None:
    deadline = time.time() + 15
    while bot in chat_identity_sync._running and time.time() < deadline:
        time.sleep(0.05)
    assert bot not in chat_identity_sync._running


def _desk_ask(r, conversation: str = "C1") -> str:
    desk = Desk(get_profile_dir(BOT), profile=BOT)
    reservation = desk.begin_ask(
        item_id="dk_test_ask", origin=Origin("agent:main:slack:dm:1", BOT), contact=OwnerContact("slack", TEAM, OWNER, None),
        target=Recipient("slack", TEAM, "U0AMY0001", conversation, None, False), question="Which room?", wait_minutes=60)
    desk.open_ask(reservation.item, "1.0")
    return reservation.item.id


def test_new_install_is_mention_only_open_to_the_workspace_and_reports_to_the_owner_dm(rig):
    r = rig()
    r.install()
    config = _config(BOT)
    assert config["platforms"]["slack"]["audience"]["policy"] == "workspace"
    assert config["platforms"]["slack"]["home_channel"] == {
        "platform": "slack", "chat_id": f"D{OWNER}", "name": "Direct messages", "user_id": OWNER, "scope_id": TEAM}
    assert config["slack"]["strict_mention"] is True
    assert "audience" not in _config("default").get("platforms", {}).get("slack", {})


def test_install_defaults_keep_what_the_owner_already_chose(rig):
    r = rig()
    path = get_profile_dir(BOT) / "config.yaml"
    atomic_yaml_write(path, {"platforms": {"slack": {"audience": {"policy": "listed", "members": ["U0AMY0001"]}}},
                             "slack": {"strict_mention": False}})
    r.install()
    config = _config(BOT)
    assert config["platforms"]["slack"]["audience"] == {"policy": "listed", "members": ["U0AMY0001"]}
    assert config["slack"]["strict_mention"] is False
    assert config["platforms"]["slack"]["home_channel"]["chat_id"] == f"D{OWNER}"


def test_audience_changes_are_compare_and_set_and_live(rig):
    r = rig()
    r.install()
    first = r.rpc("chat.audience.get")["result"]
    assert (first["policy"], first["revision"], first["members"]) == ("workspace", 0, [])
    changed = r.rpc("chat.audience.set", policy="listed", members=["U0AMY0001"], include_restricted=True,
                    member_turns_per_hour=5, expected_revision=0)["result"]
    assert changed["revision"] == 1 and changed["members"] == [{"id": "U0AMY0001", "name": "Amy Adams"}]
    with messaging._profile_scope(BOT):
        live = read_audience("slack")
    assert live.policy == AudiencePolicy.from_config(
        {"policy": "listed", "members": ["U0AMY0001"], "include_restricted": True, "member_turns_per_hour": 5})
    assert _reason(r.rpc("chat.audience.set", policy="owner_only", expected_revision=0)) == "stale_revision"
    assert _reason(r.rpc("chat.audience.set", policy="listed", members=["not a member"], expected_revision=1)) == "invalid_input"
    back = r.rpc("chat.audience.set", policy="workspace", expected_revision=1)["result"]
    assert back["members"] == [{"id": "U0AMY0001", "name": "Amy Adams"}] and back["revision"] == 2


def test_people_list_has_only_humans_of_the_workspace_and_filters_by_name(rig):
    r = rig()
    r.install()
    everyone = r.rpc("chat.people.list")["result"]
    assert [p["id"] for p in everyone["people"]] == [OWNER, "U0AMY0001", "U0GUEST01"]
    assert everyone["next_cursor"] is None
    assert [p["is_restricted"] for p in everyone["people"]] == [False, False, True]
    assert [p["id"] for p in r.rpc("chat.people.list", query="AMY")["result"]["people"]] == ["U0AMY0001"]


def test_report_destination_is_the_owner_dm_or_a_joined_channel_and_keeps_the_owner_contact(rig):
    r = rig()
    r.install()
    assert r.rpc("chat.report.get")["result"]["destination"] == {"kind": "owner_dm", "space_id": None, "name": ""}
    assert _reason(r.rpc("chat.report.set", destination={"kind": "space", "space_id": "C1"})) == "not_joined"
    moved = r.rpc("chat.report.set", destination={"kind": "space", "space_id": "G1"})["result"]["destination"]
    assert moved == {"kind": "space", "space_id": "G1", "name": "secret-plans"}
    home = _config(BOT)["platforms"]["slack"]["home_channel"]
    assert (home["chat_id"], home["user_id"], home["scope_id"]) == ("G1", OWNER, TEAM)
    assert r.rpc("chat.report.set", destination={"kind": "owner_dm"})["result"]["destination"]["kind"] == "owner_dm"
    assert _config(BOT)["platforms"]["slack"]["home_channel"]["chat_id"] == f"D{OWNER}"


def test_leaving_a_channel_drops_its_binding_retires_its_questions_and_can_repeat(rig):
    r = rig()
    r.install()
    assert r.rpc("chat.space.join", space_id="C1", hello=False)["result"]["outcome"] == "joined"
    ask = _desk_ask(r)
    assert [b["space_id"] for b in r.rpc("chat.binding.list")["result"]["bindings"]] == ["C1"]
    assert r.rpc("chat.space.leave", space_id="C1")["result"] == {"outcome": "left"}
    assert r.rpc("chat.binding.list")["result"]["bindings"] == []
    assert DeskStore(get_profile_dir(BOT)).get(ask).state.value == "expired"
    assert r.rpc("chat.space.leave", space_id="C1")["result"] == {"outcome": "not_member"}


def test_the_bots_own_picture_is_stored_per_bot_and_pushed_to_slack(rig):
    r = rig()
    r.install()
    assert _reason(r.rpc("chat.install.set_icon", data="data:image/png;base64,AAAA")) == "invalid_image"
    assert _reason(r.rpc("chat.install.set_icon", data=_png_url(64))) == "invalid_image"
    r.slack.calls.clear()
    assert r.rpc("chat.install.set_icon", data=_png_url())["result"] == {"ok": True}
    icon = get_profile_dir(BOT) / "chat_slack" / "icon.png"
    assert icon.is_file() and not (get_profile_dir("default") / "chat_slack" / "icon.png").exists()
    _wait_idle()
    assert "apps.icon.set" in r.slack.calls and "apps.manifest.update" in r.slack.calls
    assert ChatInstallStore(r.home).pending_identity(BOT) == []
    with messaging._profile_scope(BOT):
        assert profile_identity(BOT).avatar_path == str(icon)
        photo = get_profile_dir(BOT) / "assets" / "avatar.png"
        photo.parent.mkdir(parents=True, exist_ok=True)
        photo.write_bytes(icon.read_bytes())
        assert profile_identity(BOT).avatar_path == str(photo)


def test_a_failed_identity_push_stays_pending_and_the_next_connect_finishes_it(rig):
    r = rig()
    r.install()
    store = ChatInstallStore(r.home)
    r.slack.fail["apps.manifest.update"] = "network"
    chat_identity_sync.schedule_identity_sync(BOT, r.home)
    _wait_idle()
    assert len(store.pending_identity(BOT)) == 1
    del r.slack.fail["apps.manifest.update"]
    chat_identity_sync.retry_pending_identity(BOT, r.home)
    _wait_idle()
    assert store.pending_identity(BOT) == []


def test_desk_items_list_and_decide_with_the_revision_the_owner_saw(rig):
    r = rig()
    r.install()
    desk = Desk(get_profile_dir(BOT), profile=BOT)
    item = desk.request_send(
        item_id="dk_test_send", origin=Origin("agent:main:slack:dm:1", BOT), contact=OwnerContact("slack", TEAM, OWNER, None),
        to=Recipient("slack", TEAM, "U0AMY0001", None, None, True), text="Lunch is at noon", label="Amy Adams",
        wait_for_reply=False, wait_minutes=None)
    listed = _desk_rpc("chat.desk.list")["result"]["items"]
    assert [(i["id"], i["state"], i["text"], i["where"]["label"]) for i in listed] == [
        ("dk_test_send", "open", "Lunch is at noon", "Amy Adams")]
    stale = _desk_rpc("chat.desk.decide", item_id=item.id, choice="decline", expected_revision=item.revision + 1)
    assert _reason(stale) == "stale_revision" and stale["error"]["data"]["item"]["state"] == "open"
    decided = _desk_rpc("chat.desk.decide", item_id=item.id, choice="decline", expected_revision=item.revision)
    assert decided["result"]["item"]["state"] == "declined"
    assert _reason(_desk_rpc("chat.desk.decide", item_id="missing", choice="approve", expected_revision=0)) == "not_found"
    assert _desk_rpc("chat.desk.list")["result"]["items"] == []


def test_the_desk_feed_reports_each_new_revision_once(tmp_path):
    feed = DeskFeed()
    desk = Desk(tmp_path, profile="p")
    assert feed.changes([tmp_path]) == []
    item = desk.request_send(
        item_id="dk_feed", origin=Origin("k", "p"), contact=OwnerContact("slack", TEAM, OWNER, None),
        to=Recipient("slack", TEAM, "U0AMY0001", None, None, True), text="hi", label="Amy", wait_for_reply=False, wait_minutes=None)
    assert [(i.id, i.revision) for _, i in _next_changes(feed, tmp_path)] == [("dk_feed", 0)]
    assert feed.changes([tmp_path]) == []
    desk.store.transition(item.id, item.state, ItemState.DECLINED, revision=item.revision)
    assert [(i.id, i.revision) for _, i in _next_changes(feed, tmp_path)] == [("dk_feed", 1)]
