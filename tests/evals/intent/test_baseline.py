import hashlib
import json
import os
import sqlite3

import pytest

from evals.intent import baseline, fixture
from hermes_cli import goals, heartbeat
from persistence.conversation.sessions import SessionLineageKind, SessionWindow
from persistence_assembly import open_persistence, profile_scope

NOW = 1_900_000_000.0
HOUR = fixture.HOUR
say, call, result, ask, answered = fixture.say, fixture.call, fixture.result, fixture.ask, fixture.answered


def ask_raw(call_id, questions):
    return call(call_id, "clarify", {"questions": questions})


@pytest.fixture
def home(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    return tmp_path


def seed(home, session_id, messages, *, source="telegram", at=NOW - 5 * HOUR, **fields):
    if source == "telegram":
        fields.setdefault("chat_type", "dm")
    fixture.seed_session(home, session_id, source, messages, at=at, **fields)


def measure(home, **options):
    return baseline.measure([("bot", home)], days=14, now=NOW, **options)["bots"]["bot"]


def tree(root):
    return {path.relative_to(root).as_posix() for path in root.rglob("*")}


def counted(fraction):
    return fraction["count"], fraction["n"]


def test_the_synthetic_fixture_counts_exactly(home):
    fixture.seed(home, NOW)
    bot = measure(home)

    assert bot["conversations"] == 3
    assert bot["turns"] == {"owner": 9, "machine": 1, "bot": 1}
    asking = bot["asking"]
    assert counted(asking["plain_text"]) == (5, 10)
    assert counted(asking["clarify"]) == (3, 10)
    assert counted(asking["either"]) == (7, 10)
    assert counted(asking["started_by_machine"]) == (1, 7)
    assert {name: counted(value) for name, value in asking["plain_signals"].items()} == {
        "trailing_question": (4, 5), "ask_phrase": (4, 5), "option_list": (1, 5)}
    assert bot["clarify_calls"] == {"asked": 3, "rejected": 1, "not_shown": 0, "questions": 4}
    calls, questions = bot["form_coverage"]["calls"], bot["form_coverage"]["questions"]
    assert {name: counted(value) for name, value in calls.items()} == {
        "with_choices": (2, 3), "without_choices": (1, 3), "with_send": (1, 3), "recommended_first": (1, 3),
        "real_options": (2, 3), "other_row": (2, 3)}
    assert {name: counted(value) for name, value in questions.items()} == {
        "with_choices": (3, 4), "without_choices": (1, 4), "with_send": (1, 4), "recommended_first": (2, 4),
        "real_options": (3, 4), "other_row": (3, 4)}
    assert bot["repeats"] == {"asks": 9, "pairs": 3, "within_conversation": 1, "across_conversations": 2,
                              "owner_turns": 9, "per_100_owner_turns": 33.33}
    corrections = bot["corrections"]
    assert counted(corrections["after_action_or_restatement"]) == (2, 5)
    assert counted(corrections["any_follow_up"]) == (2, 6)
    assert counted(corrections["again_only"]) == (0, 5)
    assert corrections["by_shape"] == {"not_what_i_meant": 1, "wrong": 1, "y_toi_la": 1}
    assert corrections["asking_behaviour"] == {}
    work = bot["work"]
    assert counted(work["changing_turns"]) == (4, 9)
    assert {name: counted(value) for name, value in work["by_category"].items()} == {
        "code_edit": (2, 4), "outbound_send": (1, 4), "spend": (0, 4), "config": (1, 4)}
    assert counted(work["asked_first"]) == (0, 4)
    assert counted(work["restated_first"]) == (1, 4)
    assert counted(work["answering_a_question"]) == (2, 4)
    assert counted(work["no_question_or_restatement"]) == (2, 4)
    assert counted(work["unclassified_only_turns"]) == (1, 9)
    assert counted(work["machine_changing_turns"]) == (0, 1)
    assert [(row["times"], row["shape"]) for row in bot["shapes"]["repeated"]] == [
        (3, "Do you want me to send it to the _?"), (2, "When should the _ go out?")]


def test_other_peoples_conversations_and_machine_sessions_are_never_counted(home):
    asking = [say("user", "hello"), say("assistant", "Do you want the file?")]
    seed(home, "mine", asking, chat_type="dm")
    seed(home, "group", asking, chat_type="group")
    seed(home, "member", asking, chat_type="dm", session_key="agent:main:telegram:dm:7:~member")
    seed(home, "cron", asking, source="cron")
    seed(home, "room", asking, source="bot_room")
    seed(home, "child", asking, source="telegram", parent_session_id="mine", lineage_kind=SessionLineageKind.DELEGATE)
    with open_persistence(profile_scope(home=home), eager=True) as store:
        store.sessions.set_archived("mine", True)
        store.sessions.set_hidden("mine", True)

    bot = measure(home)

    assert bot["conversations"] == 1 and bot["turns"]["owner"] == 1
    assert bot["counted_sources"] == {"telegram": 1}
    assert bot["skipped_sessions"] == {"machine_source": {"bot_room": 1, "cron": 1, "telegram": 1},
                                       "not_owner_chat": {"telegram": 2}}


def test_rows_outside_the_window_are_ignored(home):
    seed(home, "old", [say("user", "a"), say("assistant", "Which one do you want?")], at=NOW - 20 * 24 * HOUR)
    assert measure(home)["turns"]["owner"] == 0


def test_a_compression_continuation_is_one_conversation(home):
    seed(home, "root", [say("user", "a"), say("assistant", fixture.LIST_QUESTION)], at=NOW - 3 * HOUR,
         end_reason="compression")
    seed(home, "tip", [say("user", "b"), say("assistant", fixture.LIST_QUESTION)], at=NOW - 2 * HOUR,
         parent_session_id="root")

    bot = measure(home)

    assert bot["conversations"] == 1
    assert (bot["repeats"]["within_conversation"], bot["repeats"]["across_conversations"]) == (1, 0)


def test_a_compaction_summary_inside_a_turn_neither_splits_it_nor_speaks_for_the_bot(home):
    seed(home, "s", [
        say("user", "tidy up"),
        say("user", "[CONTEXT COMPACTION] earlier work", display_kind="hidden", _compressed_summary=True),
        say("assistant", "Do you want the old notes?", _compressed_summary=True),
        say("assistant", "Done."),
    ])
    bot = measure(home)
    assert bot["turns"] == {"owner": 1, "machine": 0, "bot": 0}
    assert bot["asking"]["plain_text"]["count"] == 0 and bot["asking"]["either"]["n"] == 1


def test_questions_about_different_numbers_are_not_repeats(home):
    seed(home, "s", [say("user", "a"), say("assistant", "Should I merge pull request 12 now?"), say("user", "yes"),
                     say("assistant", "Should I merge pull request 13 now?")])
    assert measure(home)["repeats"]["pairs"] == 0


@pytest.mark.parametrize("first, second", [
    ("Should I deploy to staging now?", "Should I deploy to production now?"),
    (("Where should the report go?", ["Slack", "Email"]), ("Where should the report go?", ["Drive", "Notion"])),
])
def test_a_different_decision_in_similar_words_is_not_a_repeat(home, first, second):
    def turn(call_id, asked):
        if isinstance(asked, str):
            return [say("user", "go"), say("assistant", asked)]
        return [say("user", "go"), ask(call_id, {"question": asked[0], "choices": asked[1]}), answered(call_id)]

    seed(home, "s", turn("a", first) + turn("b", second))
    assert measure(home)["repeats"]["pairs"] == 0


def test_an_unshown_form_is_not_a_question_and_a_bridged_send_is_work(home):
    send = {"calls": [{"name": "mcp__gmail__send_email", "arguments": {"to": "a@example.com", "body": "hi"}}]}
    seed(home, "s", [
        say("user", "send it"),
        ask("q", {"question": "Send it?", "choices": ["Send", "Cancel"]}),
        result("q", "clarify", {"responses": [], "outcome": "not_asked"}),
        call("m", "tool_call", send),
        result("m", "tool_call", {"success": True}),
        say("assistant", "Sent."),
    ])

    bot = measure(home)

    assert bot["clarify_calls"] == {"asked": 0, "rejected": 0, "not_shown": 1, "questions": 0}
    assert bot["asking"]["either"]["count"] == 0
    assert bot["work"]["by_category"]["outbound_send"]["count"] == 1
    assert bot["work"]["no_question_or_restatement"]["count"] == 1


def test_a_question_asked_before_the_change_covers_it(home):
    seed(home, "s", [
        say("user", "tidy up"),
        ask("q", {"question": "Which folder?", "choices": ["Notes", "Drafts"]}),
        answered("q"),
        call("w", "write_file", {"path": "a"}),
        result("w", "write_file", {"bytes_written": 1}),
        say("assistant", "Done."),
    ])
    work = measure(home)["work"]
    assert work["asked_first"]["count"] == 1 and work["no_question_or_restatement"]["count"] == 0


@pytest.mark.parametrize("reply, after, again", [
    ("do it again", 0, 1),
    ("không phải vậy", 1, 0),
    ("no, that's not what I want", 1, 0),
    ("I already said the blue one", 1, 0),
    ("sai rồi, làm lại", 1, 0),
    ("thanks, looks good", 0, 0),
])
def test_correction_shapes_after_a_bot_action(home, reply, after, again):
    seed(home, "s", [say("user", "go"), call("w", "patch", {"path": "a"}), result("w", "patch", {"success": True}),
                     say("assistant", "Done."), say("user", reply), say("assistant", "Ok.")])
    corrections = measure(home)["corrections"]
    assert corrections["after_action_or_restatement"]["count"] == after
    assert corrections["again_only"]["count"] == again


def test_an_asking_behaviour_correction_reuses_the_scorecard_classes(home):
    seed(home, "s", [say("user", "go"), call("w", "patch", {"path": "a"}), say("assistant", "Done."),
                     say("user", "stop asking"), say("assistant", "Ok.")])
    assert measure(home)["corrections"]["asking_behaviour"] == {"just_do_it": 1}


def test_a_numbered_report_without_a_choice_is_not_a_question(home):
    seed(home, "s", [say("user", "what changed"), say("assistant", "Changes:\n1. Fixed the build\n2. Added a test")])
    assert measure(home)["asking"]["plain_text"]["count"] == 0


def test_shapes_keep_only_the_question_skeleton(home):
    asked = [
        "Should I email Alice at alice@example.com about invoice 99812 in \"Project Falcon\" and then keep going "
        "with a very long tail of words that never stops here?",
        "Is the password hunterswordfish still right?",
        "> my biopsy was positive, can you call me tonight?\n```\nrent money?\n```\nPick one:\n1. Reply\n2. Ignore",
        'The mail says: "I am broke. Can you lend me rent money?"',
    ]
    seed(home, "s", [row for text in asked for row in (say("user", "go"), say("assistant", text))])

    report = baseline.measure([("bot", home)], days=14, now=NOW)
    shown = json.dumps(report) + baseline.render(report)
    shapes = [row["shape"] for row in report["bots"]["bot"]["shapes"]["plain"]]

    for private in ("Alice", "alice", "99812", "Falcon", "hunterswordfish", "biopsy", "tonight", "rent", "money",
                    "broke", "never stops"):
        assert private not in shown
    assert all(len(shape) <= baseline.STEM_CAP for shape in shapes)
    assert "Is the _ still right?" in shapes
    assert any(shape.startswith("Should I _ at _") for shape in shapes)


def test_shapes_can_be_left_out(home):
    fixture.seed(home, NOW)
    assert measure(home, shapes=False)["shapes"] == {"repeated": [], "plain": []}


def test_the_store_is_opened_read_only_and_no_long_text_leaves_the_process(home, monkeypatch, capsys):
    fixture.seed(home, NOW)
    database = home / "state.db"
    before = hashlib.sha256(database.read_bytes()).hexdigest()
    with open_persistence(profile_scope(home=home), eager=True) as store:
        records = store.sessions.search_sessions(window=SessionWindow(limit=None))
        texts = [str(row.content) for record in records
                 for row in store.messages.read_transcript(record.session.session_id)]
    opened = []
    connect = sqlite3.connect

    def spy(database_arg, *args, **kwargs):
        opened.append(str(database_arg))
        return connect(database_arg, *args, **kwargs)

    monkeypatch.setattr(sqlite3, "connect", spy)
    monkeypatch.setattr(baseline.time, "time", lambda: NOW)

    assert baseline.main(["--days", "14", "--profile", "default"]) == 0

    out = capsys.readouterr().out
    store_opens = [uri for uri in opened if "state.db" in uri]
    assert store_opens and all(uri.endswith("state.db?mode=ro") for uri in store_opens)
    assert hashlib.sha256(database.read_bytes()).hexdigest() == before
    window = baseline.STEM_CAP + 1
    long_texts = [text for text in texts if len(text) >= window]
    assert long_texts
    assert not any(text[start:start + window] in out for text in long_texts
                   for start in range(len(text) - window + 1))


@pytest.mark.parametrize("argv", [[], ["--profile", "default"]])
def test_a_run_adds_nothing_to_the_home_but_sqlite_side_files(tmp_path, monkeypatch, argv):
    home = tmp_path / "measured"
    home.mkdir()
    fixture.seed(home, NOW)
    monkeypatch.setenv("HERMES_HOME", str(home))
    monkeypatch.setattr(baseline.time, "time", lambda: NOW)
    files = tree(home)

    assert baseline.main(argv) == 0

    assert files <= tree(home)
    assert tree(home) - files <= {"state.db-shm", "state.db-wal"}


def test_an_empty_store_reports_zeroes_with_their_n(home, capsys):
    with open_persistence(profile_scope(home=home), eager=True) as store:
        store.ready()

    assert baseline.main(["--profile", "default"]) == 0

    out = capsys.readouterr().out
    assert "asked in plain text" in out
    bot = measure(home)
    assert bot["status"] == "ok" and bot["turns"] == {"owner": 0, "machine": 0, "bot": 0}
    assert bot["asking"]["plain_text"] == {"count": 0, "n": 0, "share": None}
    assert bot["repeats"]["per_100_owner_turns"] is None


def test_a_profile_without_a_store_is_reported_and_nothing_is_created(home, capsys):
    assert baseline.main(["--profile", "default", "--json"]) == 0
    assert json.loads(capsys.readouterr().out)["bots"]["default"] == {"status": "no_store"}
    assert not (home / "state.db").exists()


def test_every_served_profile_is_measured_and_an_unreadable_one_leaks_nothing(home, capsys, monkeypatch):
    monkeypatch.setattr(baseline.time, "time", lambda: NOW)
    fixture.seed(home, NOW)
    broken = home / "profiles" / "broken"
    broken.mkdir(parents=True)
    (broken / "config.yaml").write_text("{}\n", encoding="utf-8")
    (broken / "state.db").write_bytes(b"SENTINEL not a database " * 64)

    assert baseline.main(["--json"]) == 1

    out = capsys.readouterr().out
    bots = json.loads(out)["bots"]
    assert bots["default"]["turns"]["owner"] == 9
    assert set(bots["broken"]) == {"status", "error"} and bots["broken"]["status"] == "error"
    assert "SENTINEL" not in out


def test_an_unknown_profile_is_an_error(home, capsys):
    assert baseline.main(["--profile", "nobody"]) == 2
    assert "nobody" in capsys.readouterr().err


def test_the_fixture_run_prints_the_table(capsys):
    assert fixture.main([]) == 0
    assert "asked in plain text" in capsys.readouterr().out


@pytest.mark.parametrize("source", ["a2a", "api_server", "ntfy", "homeassistant", "oneshot", "webui"])
def test_a_source_nobody_asks_the_owner_through_is_skipped(home, source):
    seed(home, "s", [say("user", "hi"), say("assistant", "Do you want it?")], source=source, chat_type="dm")
    bot = measure(home)
    assert bot["turns"]["owner"] == 0 and bot["skipped_sessions"] == {"machine_source": {source: 1}}


@pytest.mark.parametrize("source, fields, owner", [
    ("telegram", {"chat_type": None}, 0),
    ("telegram", {"chat_type": None, "session_key": "agent:main:telegram:dm:7"}, 1),
    ("telegram", {"chat_type": None, "session_key": "agent:main:telegram:group:7"}, 0),
    ("gui", {}, 1),
    ("local", {}, 1),
])
def test_a_missing_chat_type_counts_only_when_the_chat_is_provably_the_owners(home, source, fields, owner):
    seed(home, "s", [say("user", "hi"), say("assistant", "Done.")], source=source, **fields)
    assert measure(home)["turns"]["owner"] == owner


@pytest.mark.parametrize("prompt", [
    goals.CONTINUATION_PROMPT_TEMPLATE.format(goal="ship"),
    heartbeat.HEARTBEAT_PROMPT_TEMPLATE.format(interval="1h", prompt="check"),
    "[/loop wakeup #2]\ncheck",
    '[IMPORTANT: Background process p1 matched watch pattern "ok".\nok]',
    "[IMPORTANT: 3 background processes completed for this session.]",
])
def test_a_prompt_hermes_injected_is_not_an_owner_turn(home, prompt):
    seed(home, "s", [say("user", prompt), say("assistant", "Done.")])
    assert measure(home)["turns"] == {"owner": 0, "machine": 1, "bot": 0}


@pytest.mark.parametrize("content, corrected", [
    ('[Replying to: "he wrote ["sai rồi"] then\nI said no"]\n\nthanks', 0),
    ("[Recent channel messages]\nsomeone: I said no\n\n[New message]\nthanks", 0),
    ("[The user sent an image~ Here's what I can see:\n" + "a sign saying wrong again " * 30 + "]\n"
     "[If you need a closer look, use vision_analyze with image_url: /tmp/x.png ~]\n\nthanks", 0),
    ("[The user sent an image~ Here's what I can see:\n" + "a long description " * 30 + "]\n\nsai rồi", 1),
    ('[Replying to your previous message: "Done."]\n\nsai rồi', 1),
    ("[Tue 2026-04-28 13:40:53 UTC] không phải vậy", 1),
])
def test_only_the_words_the_owner_typed_can_be_a_correction(home, content, corrected):
    seed(home, "s", [say("user", "go"), call("w", "patch", {"path": "a"}), say("assistant", "Done."),
                     say("user", content), say("assistant", "Ok.")])
    corrections = measure(home)["corrections"]["after_action_or_restatement"]
    assert (corrections["count"], corrections["n"]) == (corrected, 1)


@pytest.mark.parametrize("name, arguments, payload, changed", [
    ("write_file", {"path": "a"}, {"error": "permission denied"}, 0),
    ("send_message", {"target": "slack:#t", "message": "hi"}, {"success": False}, 0),
    ("terminal", {"command": "false"}, {"output": "", "exit_code": 1, "error": None}, 0),
    ("write_file", {"path": "a"}, {"bytes_written": 1, "error": None}, 1),
])
def test_a_failed_call_changed_nothing(home, name, arguments, payload, changed):
    seed(home, "s", [say("user", "go"), call("c", name, arguments), result("c", name, payload),
                     say("assistant", "Done.")])
    assert measure(home)["work"]["changing_turns"]["count"] == changed


def test_a_question_before_a_silent_last_row_still_counts_but_a_form_preface_does_not(home):
    seed(home, "s", [
        say("user", "a"), call("w", "memory", {"action": "add"}, "Which file do you want?"), say("assistant", ""),
        say("user", "b"), call("q", "clarify", {"questions": [{"question": "Which?"}]}, "Here it is, ok?"),
        answered("q"), say("assistant", ""),
    ])
    assert measure(home)["asking"]["plain_text"]["count"] == 1


def test_malformed_tool_calls_never_fail_the_profile(home):
    well_formed = json.dumps([{"question": "Which one?", "choices": "Yes"}])
    seed(home, "s", [
        say("user", "go"),
        ask_raw("a", 3),
        result("a", "clarify", {"error": "bad"}),
        ask_raw("b", [{"question": "x", "choices": 2}]),
        ask_raw("c", well_formed),
        say("assistant", "", tool_calls=[{"id": "d", "function": "nonsense"}]),
        say("assistant", "Done."),
    ])
    bot = measure(home)
    assert bot["status"] == "ok"
    assert bot["clarify_calls"]["asked"] == 2
    assert bot["form_coverage"]["calls"]["with_choices"]["count"] == 0


def test_a_store_owned_by_another_user_is_not_opened(home, monkeypatch, capsys):
    fixture.seed(home, NOW)
    before = sorted(path.name for path in home.iterdir())
    owner = (home / "state.db").stat().st_uid
    monkeypatch.setattr(os, "geteuid", lambda: owner + 1, raising=False)

    assert baseline.main(["--profile", "default", "--json"]) == 1

    assert json.loads(capsys.readouterr().out)["bots"]["default"] == {"status": "not_store_owner"}
    assert sorted(path.name for path in home.iterdir()) == before
