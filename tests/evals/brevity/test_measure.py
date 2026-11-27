import hashlib
import json
import os
import sqlite3
import subprocess
import sys
import time
from pathlib import Path

import pytest

from evals.brevity import fixture, measure
from evals.intent.fixture import call, result, say, seed_session
from evals.intent.transcripts import read_conversations
from gateway.session_timeline import _display_rows
from gateway.session_timeline_entries import reply_entries, timeline_entries
from hermes_state import SessionDB

NOW = 1_900_000_000.0
HOUR = 3600.0
REPO = Path(__file__).resolve().parents[3]
PROCESS = "[IMPORTANT: Background process proc_a completed normally (exit code 0).\nCommand: make\nOutput:\nok]"
BOT_DM = "Message from 🤖 Atlas (@atlas): status please"


@pytest.fixture
def home(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    return tmp_path


def notice(text=PROCESS, kind="process_complete"):
    return say("user", text, display_kind=kind)


def seed(home, session_id, messages, *, source="telegram", at=NOW - 5 * HOUR, **fields):
    if source == "telegram":
        fields.setdefault("chat_type", "dm")
    seed_session(home, session_id, source, messages, at=at, **fields)


def bot_of(home, days=1):
    return measure.measure([("bot", home)], days=days, now=NOW)["bots"]["bot"]


def views(home):
    return bot_of(home)["views"]


def origins(view):
    return {name: cell["count"] for name, cell in view["consecutive"]["by_origin"].items()}


def tree(root):
    return {path.relative_to(root).as_posix() for path in root.rglob("*")}


def stored_texts(home):
    with sqlite3.connect(f"file:{home / 'state.db'}?mode=ro", uri=True) as db:
        rows = db.execute("SELECT content FROM messages WHERE content IS NOT NULL").fetchall()
        ids = db.execute("SELECT id FROM sessions").fetchall()
    return [line for (content,) in rows for line in str(content).split("\n") if len(line) >= 6] + [i for (i,) in ids]


def test_the_synthetic_fixture_counts_exactly(home):
    fixture.seed(home, NOW)
    bot = bot_of(home)

    assert bot["conversations"] == 7
    stored, shown = bot["views"]["stored"], bot["views"]["shown"]
    assert (stored["owner_turns"], shown["owner_turns"]) == (8, 8)
    assert (stored["bubbles"], shown["bubbles"]) == (14, 11)
    assert stored["turns_by_bubbles"] == {"0": 0, "1": 2, "2": 6, "3+": 0}
    assert shown["turns_by_bubbles"] == {"0": 0, "1": 5, "2": 3, "3+": 0}
    assert stored["bubbles_per_owner_turn"] == {"mean": 1.75, "p50": 2, "p90": 2}
    assert shown["bubbles_per_owner_turn"] == {"mean": 1.38, "p50": 1, "p90": 2}
    assert (stored["consecutive"]["count"], stored["consecutive"]["n"], stored["consecutive"]["share"]) == (
        6, 14, 0.4286)
    assert origins(stored) == {"same_turn": 1, "notice_turn": 3, "other_turn": 2}
    assert origins(shown) == {"same_turn": 0, "notice_turn": 1, "other_turn": 2}
    assert shown["consecutive"]["by_origin"]["other_turn"] == {"count": 2, "n": 3, "share": 0.6667}
    assert stored["bubbles_before_first_owner"] == shown["bubbles_before_first_owner"] == 0


def test_only_a_row_the_owner_wrote_opens_an_owner_turn(home):
    seed(home, "s", [
        say("user", "go"), say("assistant", "one"),
        notice(), say("assistant", "two?"),
        say("user", BOT_DM), say("assistant", "three"),
        say("user", '[Cronjob "digest"] run now'), say("assistant", "four"),
        say("user", [{"type": "image_url", "image_url": {"url": "data:image/png;base64,iVBOR"}}]),
        say("assistant", "five"),
    ])
    stored = views(home)["stored"]
    assert (stored["owner_turns"], stored["bubbles"]) == (2, 5)
    assert stored["turns_by_bubbles"] == {"0": 0, "1": 1, "2": 0, "3+": 1}
    assert origins(stored) == {"same_turn": 0, "notice_turn": 1, "other_turn": 2}


def test_a_turn_without_words_has_no_bubble_and_empty_replies_are_not_bubbles(home):
    seed(home, "s", [
        say("user", "go"), call("c", "terminal", {"command": "true"}), result("c", "terminal", {"exit_code": 0}),
        say("assistant", "   "),
        say("user", "again"), say("assistant", "[SILENT]"),
    ])
    for view in views(home).values():
        assert (view["owner_turns"], view["bubbles"]) == (2, 0)
        assert view["turns_by_bubbles"] == {"0": 2, "1": 0, "2": 0, "3+": 0}
        assert view["bubbles_per_owner_turn"] == {"mean": 0.0, "p50": 0, "p90": 0}
        assert view["words_per_bubble"] == {"p50": None, "p90": None}
        assert view["consecutive"]["share"] is None


def test_bubbles_before_the_first_owner_row_are_counted_apart_per_conversation(home):
    seed(home, "a", [say("assistant", "resumed"), notice(), say("assistant", "Blocked: need a key?"),
                     say("user", "go"), say("assistant", "ok")], at=NOW - 4 * HOUR)
    seed(home, "b", [notice(), say("assistant", "finished")], at=NOW - 3 * HOUR)
    stored = views(home)["stored"]
    assert (stored["owner_turns"], stored["bubbles"], stored["bubbles_before_first_owner"]) == (1, 1, 3)
    assert stored["consecutive"]["count"] == 0


def test_a_joined_bubble_ends_at_its_last_part_for_the_next_origin(home):
    seed(home, "s", [
        say("user", "go"), say("assistant", "started"),
        notice(),
        call("c", "image_generate", {"prompt": "x"}, "drawing"), result("c", "image_generate", {"success": True}),
        say("assistant", "drawn"),
        say("user", "thanks"), say("assistant", "bye"),
    ])
    shown = views(home)["shown"]
    assert (shown["owner_turns"], shown["bubbles"], shown["consecutive"]["count"]) == (2, 2, 0)
    stored = views(home)["stored"]
    assert origins(stored) == {"same_turn": 1, "notice_turn": 1, "other_turn": 0}


def test_a_routine_card_painted_from_a_user_row_is_not_part_of_the_turn_before_it(home):
    seed(home, "s", [
        say("user", "go"), say("assistant", "started"),
        say("user", '[Cronjob "digest" output]', display_kind="routine_output",
            display_metadata={"display_text": "Three pull requests are open."}),
    ])
    stored = views(home)["stored"]
    assert stored["bubbles"] == 2
    assert origins(stored)["same_turn"] == 0 and sum(origins(stored).values()) == 1


def test_words_per_bubble_use_nearest_rank_percentiles(home):
    rows = [row for count in range(1, 11) for row in
            (say("user", "go"), say("assistant", " ".join(["word"] * count)))]
    seed(home, "s", rows)
    assert views(home)["stored"]["words_per_bubble"] == {"p50": 5, "p90": 9}


def test_rows_outside_the_window_are_ignored_and_the_window_defaults_to_one_day(home, capsys, monkeypatch):
    seed(home, "old", [say("user", "old"), say("assistant", "old reply")], at=NOW - 30 * HOUR)
    seed(home, "new", [say("user", "new"), say("assistant", "new reply")])
    monkeypatch.setattr(measure.time, "time", lambda: NOW)

    assert measure.main(["--profile", "default", "--json"]) == 0

    report = json.loads(capsys.readouterr().out)
    assert report["window"]["days"] == 1
    assert report["bots"]["default"]["views"]["stored"]["owner_turns"] == 1
    assert bot_of(home, days=2)["views"]["stored"]["owner_turns"] == 2


def test_a_compression_continuation_is_one_conversation_with_each_row_once(home):
    first = [say("user", "go"), say("assistant", "started")]
    seed(home, "root", first, at=NOW - 3 * HOUR, end_reason="compression")
    seed(home, "tip", [], at=NOW - 3 * HOUR, parent_session_id="root")
    with SessionDB(home / "state.db") as db:
        for index, row in enumerate([*first, notice(), say("assistant", "done")]):
            db.append_message("tip", row["role"], row["content"], display_kind=row.get("display_kind"),
                              timestamp=NOW - 3 * HOUR + index)
    bot = bot_of(home)
    assert bot["conversations"] == 1
    assert (bot["views"]["stored"]["owner_turns"], bot["views"]["stored"]["bubbles"]) == (1, 2)


def test_the_rows_fed_to_the_projection_paint_what_the_gateway_paints(home):
    seed(home, "root", [
        say("user", "go"), say("assistant", "  started  ", reasoning="plan"), notice(),
        say("assistant", [{"type": "text", "text": "one"}, {"type": "text", "text": "two"}]),
    ], at=NOW - 4 * HOUR, end_reason="compression")
    seed(home, "tip", [
        say("user", "draw"),
        call("c", "image_generate", {"prompt": "x"}, "drawing"), result("c", "image_generate", {"success": True}),
        say("assistant", "drawn"),
    ], at=NOW - 3 * HOUR, parent_session_id="root")
    with SessionDB(home / "state.db") as db:
        db.archive_and_compact("tip", [say("user", "[CONTEXT COMPACTION — REFERENCE ONLY] earlier work")],
                               watermark=db.get_active_message_watermark("tip"), tail_count=0)
        db.append_message("tip", "user", PROCESS, display_kind="process_complete", timestamp=NOW - 2 * HOUR)
        db.append_message("tip", "assistant", "all done", timestamp=NOW - 2 * HOUR + 1)
        gateway = _display_rows(db, "tip")
    [conversation] = read_conversations(home, 0.0).conversations
    fed = measure.projection_rows(conversation)
    for project in (reply_entries, timeline_entries):
        assert project(fed, conversation.live_ids, str(home)) == project(*gateway, str(home))


def test_a_group_chat_and_a_cron_session_are_never_counted(home):
    spoken = [say("user", "hi"), say("assistant", "hello")]
    seed(home, "mine", spoken)
    seed(home, "group", spoken, chat_type="group", at=NOW - 4 * HOUR)
    seed(home, "cron", spoken, source="cron", at=NOW - 3 * HOUR)
    bot = bot_of(home)
    assert bot["conversations"] == 1 and bot["counted_sources"] == {"telegram": 1}
    assert bot["skipped_sessions"] == {"machine_source": {"cron": 1}, "not_owner_chat": {"telegram": 1}}


def test_the_script_reports_on_real_stdout_leaks_nothing_and_writes_nothing(tmp_path):
    home = tmp_path / "measured"
    home.mkdir()
    fixture.seed(home, time.time())
    database = home / "state.db"
    digest = hashlib.sha256(database.read_bytes()).hexdigest()
    files = tree(home)
    env = {**os.environ, "HERMES_HOME": str(home), "HOME": str(tmp_path)}

    run = subprocess.run(
        [sys.executable, "evals/brevity/measure.py", "--days", "1", "--profile", "default"],
        cwd=REPO, env=env, capture_output=True, text=True, timeout=120, check=False)

    assert run.returncode == 0, run.stderr
    report, _ = json.JSONDecoder().raw_decode(run.stdout)
    assert report["bots"]["default"]["views"]["shown"]["bubbles"] == 11
    assert "bubbles per owner turn" in run.stdout and "bubbles per owner turn" not in run.stderr
    private = stored_texts(home)
    assert private and not [text for text in private if text in run.stdout or (len(text) > 12 and text in run.stderr)]
    assert str(home) not in run.stdout
    assert hashlib.sha256(database.read_bytes()).hexdigest() == digest
    assert files <= tree(home)
    assert tree(home) - files <= {"state.db-shm", "state.db-wal"}


def test_the_store_is_opened_read_only(home, monkeypatch, capsys):
    fixture.seed(home, NOW)
    opened = []
    connect = sqlite3.connect

    def spy(database, *args, **kwargs):
        opened.append(str(database))
        return connect(database, *args, **kwargs)

    monkeypatch.setattr(sqlite3, "connect", spy)
    monkeypatch.setattr(measure.time, "time", lambda: NOW)

    assert measure.main(["--profile", "default"]) == 0

    assert "bubbles per owner turn" in capsys.readouterr().out
    stores = [uri for uri in opened if "state.db" in uri and str(home) in uri]
    assert stores and all(uri.endswith("state.db?mode=ro") for uri in stores)


def test_every_served_profile_is_measured_and_an_unreadable_one_leaks_nothing(home, capsys, monkeypatch):
    monkeypatch.setattr(measure.time, "time", lambda: NOW)
    fixture.seed(home, NOW)
    broken = home / "profiles" / "broken"
    broken.mkdir(parents=True)
    (broken / "config.yaml").write_text("{}\n", encoding="utf-8")
    (broken / "state.db").write_bytes(b"SENTINEL not a database " * 64)

    assert measure.main(["--json"]) == 1

    out = capsys.readouterr().out
    bots = json.loads(out)["bots"]
    assert bots["default"]["views"]["stored"]["owner_turns"] == 8
    assert set(bots["broken"]) == {"status", "error"} and bots["broken"]["status"] == "error"
    assert "SENTINEL" not in out


def test_a_missing_store_is_reported_and_a_foreign_one_is_not_opened(home, capsys, monkeypatch):
    assert measure.main(["--profile", "default", "--json"]) == 0
    assert json.loads(capsys.readouterr().out)["bots"]["default"] == {"status": "no_store"}
    assert not (home / "state.db").exists()

    fixture.seed(home, NOW)
    owner = (home / "state.db").stat().st_uid
    monkeypatch.setattr(os, "geteuid", lambda: owner + 1, raising=False)

    assert measure.main(["--profile", "default"]) == 1

    assert "== default: not_store_owner" in capsys.readouterr().out


@pytest.mark.parametrize("argv", [["--profile", "nobody"], ["--days", "0"]])
def test_a_bad_argument_exits_with_a_usage_error(home, capsys, argv):
    try:
        status = measure.main(argv)
    except SystemExit as exit_:
        status = exit_.code
    assert status == 2 and capsys.readouterr().err


def test_the_fixture_run_prints_the_report(capsys):
    assert fixture.main([]) == 0
    assert "bubbles per owner turn" in capsys.readouterr().out
