"""The teach-a-skill event log is the privacy gate: what a demonstration may leave on disk."""

from __future__ import annotations

import json
import os
import stat
import time

import pytest

from tools.bot_desktop import teach_log
from tools.bot_desktop.teach_log import SECRET_MARKER, TeachLog, sanitize, strip_url


def _type(value, **field):
    return {"kind": "type", "page": "https://shop.example/login",
            "target": {"role": "textbox", "name": "Field", "selector": "#f", **field}, "value": value}


@pytest.mark.parametrize("field", [
    {"input_type": "password"},
    {"autocomplete": "one-time-code"},
    {"autocomplete": "cc-number"},
    {"autocomplete": "cc-csc"},
    {"autocomplete": "off current-password"},
    {"name": "Verification code"},
    {"label": "Card number"},
    {"placeholder": "Your API key"},
    {"field_name": "otp"},
    {"field_name": "pwd"},
    {"field_name": "user_pw"},
    {"field_id": "passwd"},
    {"field_id": "userPassword"},
    {"name": "PIN"},
])
def test_secret_fields_never_keep_their_value(field):
    event = sanitize(_type("hunter2-VERY-secret", **field))
    assert event["value"] == SECRET_MARKER
    assert "hunter2" not in json.dumps(event)


def test_the_page_script_cannot_downgrade_a_secret_flag_but_a_plain_field_stays_readable():
    assert sanitize(_type("x", input_type="text"))["value"] == "x"
    flagged = {**_type("leaked"), "secret": True}
    assert sanitize(flagged)["value"] == SECRET_MARKER
    assert sanitize(_type("ada@example.com", input_type="email", autocomplete="email"))["value"] == "ada@example.com"


def test_a_secret_shaped_value_in_an_ordinary_field_is_masked():
    event = sanitize(_type("sk-proj-abcdefghijklmnopqrstuvwxyz0123456789", input_type="text"))
    assert "abcdefghijklmnopqrstuvwxyz0123456789" not in event["value"]


def test_typed_values_and_names_are_capped_and_control_characters_removed():
    event = sanitize(_type("a" * 5000 + "\x00\x1b[31m", input_type="text"))
    assert len(event["value"]) <= teach_log.MAX_VALUE_CHARS
    assert "\x00" not in json.dumps(sanitize({"kind": "click", "target": {"role": "button", "name": "Go\x00\n" * 100}}))
    assert len(sanitize({"kind": "click", "target": {"role": "button", "name": "n" * 999}})["target"]["name"]) <= teach_log.MAX_NAME_CHARS


@pytest.mark.parametrize("raw, expected", [
    ("https://app.example.com/a/b?token=SECRET&x=1#frag", "https://app.example.com/a/b"),
    ("http://user:pass@host.example:8080/p?q=1", "http://host.example:8080/p"),
    ("https://example.com/reset/Zx9Qk2Lm7Pa4Vb8Nc3Td5Ye/confirm", "https://example.com/reset/<id>/confirm"),
    ("https://example.com/orders/12345", "https://example.com/orders/12345"),
    ("https://example.com/reset/abc12345", "https://example.com/reset/<id>"),
    ("https://example.com/u/jane.doe@corp.com/inbox", "https://example.com/u/<id>/inbox"),
    ("https://example.com/share/3f2b8c1e-aa11-4d2e-9c77-0a1b2c3d4e5f", "https://example.com/share/<id>"),
    ("https://example.com/docs/getting-started", "https://example.com/docs/getting-started"),
    ("HTTPS://Example.COM", "https://example.com"),
])
def test_urls_keep_scheme_host_and_path_only(raw, expected):
    assert strip_url(raw) == expected


@pytest.mark.parametrize("raw", [
    "about:blank", "chrome://settings", "data:text/html,<script>x</script>", "javascript:alert(1)",
    "blob:https://example.com/uuid", "file:///etc/passwd", "", None, "http://", "https://[::1",
])
def test_urls_that_are_not_web_pages_are_not_logged(raw):
    assert strip_url(raw) is None
    assert sanitize({"kind": "navigate", "url": raw}) is None


def test_download_keeps_a_bare_filename_and_a_stripped_url():
    event = sanitize({"kind": "download", "filename": "../../etc/passwd", "url": "https://x.example/f?sig=SECRET"})
    assert event == {"kind": "download", "filename": "passwd", "url": "https://x.example/f"}


def test_only_enter_and_escape_are_logged_as_keys():
    assert sanitize({"kind": "key", "key": "Enter"}) == {"kind": "key", "key": "Enter"}
    for key in ("a", "Backspace", "Tab", "Control", "p", "F5", None):
        assert sanitize({"kind": "key", "key": key}) is None


@pytest.mark.parametrize("raw", [None, "x", [], {}, {"kind": "eval"}, {"kind": "click"}, {"kind": "click", "target": "#a"},
                                 {"kind": "type", "target": {}}])
def test_malformed_events_are_dropped(raw):
    assert sanitize(raw) is None


def test_log_is_private_even_under_a_permissive_umask(tmp_path):
    old = os.umask(0)
    try:
        log = TeachLog("teach-aaaaaaaa")
        log.add({"kind": "navigate", "url": "https://example.com/"})
    finally:
        os.umask(old)
    assert stat.S_IMODE(log.directory.stat().st_mode) == 0o700
    assert stat.S_IMODE(log.directory.parent.stat().st_mode) == 0o700
    assert stat.S_IMODE(log.path.stat().st_mode) == 0o600


def test_nothing_secret_reaches_the_file():
    log = TeachLog("teach-bbbbbbbb")
    log.add(_type("hunter2-VERY-secret", input_type="password"))
    log.add({"kind": "navigate", "url": "https://example.com/p?code=OAUTHCODE#frag"})
    raw = log.path.read_text(encoding="utf-8")
    assert "hunter2" not in raw and "OAUTHCODE" not in raw and "frag" not in raw
    assert [e["kind"] for e in log.events()] == ["type", "navigate"]


def test_consecutive_identical_navigations_collapse():
    log = TeachLog("teach-cccccccc")
    assert log.add({"kind": "navigate", "url": "https://example.com/a?x=1"})
    assert not log.add({"kind": "navigate", "url": "https://example.com/a?x=2"})
    assert log.add({"kind": "navigate", "url": "https://example.com/b"})
    assert log.count == 2


def test_event_count_cap_truncates_and_counts_what_was_dropped(monkeypatch):
    monkeypatch.setattr(teach_log, "MAX_EVENTS", 5)
    log = TeachLog("teach-dddddddd")
    results = [log.add({"kind": "click", "target": {"role": "button", "name": f"b{i}"}}) for i in range(8)]
    assert results == [True] * 5 + [False] * 3
    assert log.truncated and log.dropped == 3 and len(log.events()) == 5


def test_byte_cap_stops_the_log_before_it_exceeds_the_limit(monkeypatch):
    monkeypatch.setattr(teach_log, "MAX_LOG_BYTES", 600)
    log = TeachLog("teach-eeeeeeee")
    for i in range(50):
        log.add({"kind": "click", "target": {"role": "button", "name": "x" * 100 + str(i)}})
    assert log.truncated and log.path.stat().st_size <= 600
    assert len(log.events()) == log.count < 50


def test_delete_removes_the_directory_and_events_alone_keeps_meta():
    log = TeachLog("teach-ffffffff")
    log.add({"kind": "navigate", "url": "https://example.com/"})
    (log.directory / "meta.json").write_text("{}")
    teach_log.delete_events("teach-ffffffff")
    assert not log.path.exists() and (log.directory / "meta.json").exists()
    log.delete()
    assert not log.directory.exists()


def test_purge_removes_only_old_recordings_that_never_became_drafts():
    old, fresh, kept, draft, live = (TeachLog(f"teach-{n}000000") for n in ("old", "new", "kep", "dra", "liv"))
    for entry in (old, kept, draft):
        past = time.time() - 2 * teach_log.ORPHAN_MAX_AGE_SECONDS
        os.utime(entry.directory, (past, past))
    (draft.directory / "meta.json").write_text("{}")
    removed = teach_log.purge_orphans(keep=frozenset({"teach-liv000000", "teach-kep000000"}))
    assert removed == ["teach-old000000"]
    assert not old.directory.exists()
    assert all(e.directory.exists() for e in (fresh, kept, draft, live))


@pytest.mark.parametrize("bad", ["../x", "a/b", "", "teach", "TEACH-AAAAAAAA", None, 5, "teach-abcdefgh\n"])
def test_teach_ids_cannot_escape_the_root(bad):
    assert not teach_log.valid_teach_id(bad)
    with pytest.raises(ValueError):
        teach_log.teach_dir(bad)


def test_a_closed_log_ignores_whatever_a_late_capture_reports():
    log = TeachLog("teach-99999999")
    assert log.add({"kind": "navigate", "url": "https://example.com/"})
    log.close()
    assert not log.add({"kind": "navigate", "url": "https://example.com/late"})
    assert len(log.events()) == 1


def test_a_field_that_was_a_password_field_stays_secret_after_a_show_password_toggle():
    toggled = {**_type("hunter2", input_type="text"), "secret": True}
    assert sanitize(toggled)["value"] == SECRET_MARKER
