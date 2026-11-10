import json
import subprocess
import sys
from pathlib import Path

import pytest

from tools import bot_dm_wire as wire
from tools import bot_relay

REPO = Path(__file__).resolve().parents[2]


def _waiter_stdout(tmp_path, reply_payload, label="@researcher on mini"):
    reply = tmp_path / "reply.json"
    reply.write_text(json.dumps(reply_payload), encoding="utf-8")
    proc = subprocess.run([sys.executable, str(REPO / "tools" / "bot_mode_dm.py"), "--wait-reply", str(reply), label, "5"],
                          capture_output=True, check=False)
    return proc.returncode, proc.stdout


@pytest.mark.parametrize("payload, code, stdout", [
    ({"reply": "pong"}, 0, b"Reply from @researcher on mini:\npong\n"),
    ({"reply": ""}, 0, b"Reply from @researcher on mini:\n(empty reply)\n"),
    ({"error": "offline", "reason": "runtime_offline"}, 1,
     b"Delivery to @researcher on mini failed [reason: runtime_offline]: offline\n"),
    ({"error": "boom", "reason": ""}, 1, b"Delivery to @researcher on mini failed: boom\n"),
])
def test_relay_waiter_completion_bytes_are_unchanged(tmp_path, payload, code, stdout):
    assert _waiter_stdout(tmp_path, payload) == (code, stdout)


def test_sender_stamp_bytes_are_unchanged_and_parse_back():
    stamped = wire.format_sender_stamp("Maia Prime", "hermes", "status?\nline two")
    assert stamped.encode() == "Message from 🤖 Maia Prime (@hermes): status?\nline two".encode()
    parsed = wire.split_sender_stamp(stamped)
    assert (parsed.display_name, parsed.handle, parsed.connection, parsed.body, parsed.form) == (
        "Maia Prime", "hermes", None, "status?\nline two", "stamp")


def test_relay_qualified_stamp_bytes_are_unchanged_and_keep_the_connection():
    roster = [{"profile": "default", "handle": "hermes", "connection_id": "mini", "connection_label": "Mini"}]
    assert (bot_relay.qualify_sender_stamp("Message from 🤖 Maia (@hermes): hi", "hermes", "mini", roster)
            == "Message from 🤖 Maia (@hermes): hi")
    qualified = bot_relay.qualify_sender_stamp("Message from 🤖 Maia (@hermes): hi", "hermes", "mini", [])
    assert qualified == "Message from 🤖 Maia (@hermes@mini): hi"
    parsed = wire.split_sender_stamp(qualified)
    assert (parsed.handle, parsed.connection, parsed.body) == ("hermes", "mini", "hi")
    assert bot_relay.qualify_sender_stamp("plain text", "hermes", "mini", roster) == "plain text"


def test_legacy_stamp_parses_and_unstamped_text_does_not():
    legacy = wire.split_sender_stamp("[Message from agent 'scout'] found it")
    assert (legacy.handle, legacy.body, legacy.form) == ("scout", "found it", "legacy")
    assert wire.split_sender_stamp("hello there") is None


@pytest.mark.parametrize("raw", ["bot:" + "a" * 64, "bot:" + "a" * 64 + ":retry", "a" * 64])
def test_a_retry_is_the_same_delivery(raw):
    assert wire.DeliveryKey.parse(raw) == wire.DeliveryKey("a" * 64)


@pytest.mark.parametrize("raw, expected", [("bot:" + "a" * 64, "a" * 64), ("bot:" + "a" * 32 + ":retry", "a" * 32),
                                           ("a" * 32, None), ("a" * 64 + ":retry", None)])
def test_only_a_bot_prefixed_request_id_is_a_delivery_turn(raw, expected):
    key = wire.DeliveryKey.from_request_id(raw)
    assert (key.delivery_id if key else None) == expected


@pytest.mark.parametrize("raw", ["bot-chat:default", "cron:job", "bot:xyz", "", None])
def test_non_delivery_request_ids_are_not_deliveries(raw):
    assert wire.DeliveryKey.parse(raw) is None


@pytest.mark.parametrize("label, expected", [
    ("@researcher", wire.TargetLabel("local", "researcher")),
    (wire.format_peer_label("researcher", "spark"), wire.TargetLabel("peer", "researcher", peer="spark")),
    (wire.format_relay_label("hermes", "Mini Mac"), wire.TargetLabel("relay", "hermes", connection="Mini Mac")),
])
def test_ack_target_labels_parse_back(label, expected):
    assert wire.parse_target_label(label) == expected
    assert wire.format_peer_label("researcher", "spark") == "@researcher on peer 'spark'"
