import json

import pytest

from evals.proactive_eval import cli
from evals.proactive_eval.fixture_source import FIXTURE_PATH, FixtureSource
from gateway.proactive_scorecard import mining
from gateway.proactive_scorecard.mining import AskItem, Message, MinedSession, QuestionContext
from gateway.proactive_scorecard.rubric import Criterion
from persistence_assembly import open_persistence, profile_scope
from tests.fixtures.storage_seed import seed_messages, seed_session
from tests.gateway.proactive_scorecard.card_fixture import BOT_CHAT_WINDOW, DAY, NOW, seed_bot_chat

WEEK_2026_W10 = 1772409600.0
HOUR = 3600.0


class ListSource:
    def __init__(self, *sessions):
        self._sessions = sessions

    def sessions(self, since, until):
        return iter(self._sessions)


def convo(*pairs, start=WEEK_2026_W10, bot="alpha"):
    messages = tuple(Message(role, text, start + i * 60.0) for i, (role, text) in enumerate(pairs))
    return MinedSession(bot, start, messages)


def total(report, bot="alpha"):
    return report["bots"][bot]["total"]


def test_question_turns_are_labelled_and_rated():
    session = convo(("user", "tidy the notes"), ("assistant", "Should I go ahead and rename them?"), ("user", "yes"),
                    ("assistant", "Done. Can you send me the password for the archive?"), ("user", "hunter"),
                    ("assistant", "Archived."))
    stats = total(mining.mine({"alpha": ListSource(session)}))
    assert (stats["question_turns"], stats["avoidable"], stats["needed"]) == (2, 1, 1)
    assert stats["avoidable_rate"] == 0.5
    assert stats["owner_turns_to_done"]["n"] == 1 and stats["owner_turns_to_done"]["mean"] == 3


def test_a_session_ending_on_a_question_is_open_not_done():
    stats = total(mining.mine({"alpha": ListSource(convo(("user", "do it"), ("assistant", "Which file?")))}))
    assert stats["open_sessions"] == 1 and stats["owner_turns_to_done"]["n"] == 0


def test_corrections_count_by_class_and_after_a_question():
    session = convo(("user", "fix it"), ("assistant", "Should I proceed?"), ("user", "just do it, stop asking"),
                    ("assistant", "Fixed."), ("user", "chỉ hỏi những gì cần thiết"), ("assistant", "Ok."))
    stats = total(mining.mine({"alpha": ListSource(session)}))
    assert stats["corrections"] == {"ask_only_needed": 1, "just_do_it": 1}
    assert stats["corrections_after_question"] == 1


def test_a_clarify_call_is_a_question_turn_even_without_a_question_mark():
    session = MinedSession("alpha", WEEK_2026_W10, (
        Message("user", "plan", WEEK_2026_W10), Message("assistant", "Details sent.", WEEK_2026_W10 + 1, (AskItem("Approve sending?", ("Send as written", "Cancel")),)),
        Message("user", "ok", WEEK_2026_W10 + 2), Message("assistant", "Sent.", WEEK_2026_W10 + 3)))
    stats = total(mining.mine({"alpha": ListSource(session)}))
    assert stats["question_turns"] == 1 and stats["needed"] == 1


def test_a_judge_hook_overrides_the_heuristic():
    session = convo(("user", "go"), ("assistant", "Which colour?"), ("user", "blue"), ("assistant", "Done."))
    seen = []

    def judge(context: QuestionContext):
        seen.append(context)
        return frozenset({Criterion.SAFE_DEFAULT})

    report = mining.mine({"alpha": ListSource(session)}, judge=judge)
    assert report["judge"] == "model" and total(report)["avoidable"] == 1
    assert seen[0].question == "Which colour?" and seen[0].recent == ("go",)


def test_sessions_are_bucketed_by_iso_week_per_bot():
    later = WEEK_2026_W10 + 7 * 86400.0
    report = mining.mine({"alpha": ListSource(convo(("user", "a"), ("assistant", "ok")), convo(("user", "b"), ("assistant", "ok"), start=later)),
                          "bravo": ListSource(convo(("user", "c"), ("assistant", "ok"), bot="bravo"))})
    assert list(report["bots"]["alpha"]["weeks"]) == ["2026-W10", "2026-W11"]
    assert total(report, "bravo")["sessions"] == 1


def test_a_session_without_owner_turns_is_ignored():
    stats = total(mining.mine({"alpha": ListSource(convo(("assistant", "scheduled report ready")))}))
    assert stats["sessions"] == 0


def test_the_bundled_fixture_mines_to_counts_with_a_heuristic_baseline():
    fixture = FixtureSource()
    report = mining.mine({bot: FixtureSource(bot=bot) for bot in fixture.bots()}, source_label="synthetic-fixture")
    assert set(report["bots"]) >= {"alpha", "bravo", "charlie"}
    stats = [total(report, bot) for bot in report["bots"]]
    assert all(s["sessions"] > 0 and s["question_turns"] > 0 for s in stats)
    assert all(s["corrections_total"] > 0 for s in stats)
    agreement = [s["heuristic_agreement"] for s in stats]
    assert sum(a["agree"] for a in agreement) / sum(a["n"] for a in agreement) >= 0.7


def test_the_miner_output_holds_no_message_text(capsys):
    assert cli.main(["mine", "--dry-run"]) == 0
    out = capsys.readouterr().out
    report = json.loads(out)
    assert report["source"] == "synthetic-fixture" and report["judge"] == "heuristic"
    lines = FIXTURE_PATH.read_text(encoding="utf-8").splitlines()
    forbidden = {m["text"] for line in lines for m in json.loads(line)["messages"]}
    assert not any(text[:30] in out for text in forbidden if len(text) >= 30)


def test_dry_run_opens_no_store(monkeypatch, tmp_path):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    monkeypatch.setattr(mining.PersistenceSource, "sessions", lambda *a, **k: pytest.fail("store opened"))
    assert cli.main(["mine", "--dry-run", "--out", str(tmp_path / "out.json")]) == 0
    assert (tmp_path / "out.json").exists()


def test_since_filters_the_window(capsys):
    assert cli.main(["mine", "--dry-run", "--since", "2099-01-01"]) == 0
    report = json.loads(capsys.readouterr().out)
    assert all(b["total"]["sessions"] == 0 for b in report["bots"].values())


@pytest.mark.parametrize("value, expected", [("2026-03-02", WEEK_2026_W10), ("3d", 1000.0 - 3 * 86400), (None, None)])
def test_moment_parsing(value, expected):
    assert cli.parse_moment(value, now=1000.0) == expected


def test_the_store_source_reads_a_real_store_read_only(tmp_path):
    tool_call = {"id": "c1", "type": "function",
                 "function": {"name": "clarify", "arguments": json.dumps({"questions": [{"question": "Approve sending?"}]})}}
    with open_persistence(profile_scope(home=tmp_path), eager=True) as writer:
        seed_session(writer, "s1", "telegram")
        seed_messages(writer, "s1", {"role": "user", "content": "send the note to the team"},
                      {"role": "assistant", "content": "Should I go ahead and draft it?"},
                      {"role": "user", "content": "just do it"},
                      {"role": "assistant", "content": "Details above.", "tool_calls": [tool_call]},
                      {"role": "user", "content": "yes"},
                      {"role": "assistant", "content": "Sent."})
        seed_session(writer, "cron1", "cron")
        seed_messages(writer, "cron1", {"role": "user", "content": "tick"}, {"role": "assistant", "content": "Is it ok?"})
        before = writer.messages.read_transcript("s1")

        report = mining.mine({"alpha": mining.PersistenceSource(tmp_path, bot="alpha")}, source_label="store")
        after = writer.messages.read_transcript("s1")

    stats = total(report)
    assert stats["sessions"] == 1
    assert stats["question_turns"] == 2 and stats["avoidable"] == 1
    assert stats["corrections"] == {"just_do_it": 1}
    assert [r.id for r in before] == [r.id for r in after]


def test_ask_quality_counts_options_recommendation_bare_yes_no_and_bare_open_questions():
    session = convo(
        ("user", "go"),
        ("assistant", "Draft ready.\n1. Send as written (recommended)\n2. Edit then send\n3. Cancel\nWhich one?"),
        ("user", "1"),
        ("assistant", "Shall I archive it?"),
        ("user", "yes"),
        ("assistant", "I'll assume the default folder. Which name do you want?"),
        ("user", "notes"),
        ("assistant", "Done."))
    quality = total(mining.mine({"alpha": ListSource(session)}))["ask_quality"]
    assert quality["asks"] == 3 and quality["with_options_share"] == round(1 / 3, 4)
    assert quality["no_options_no_default_share"] == round(1 / 3, 4)
    assert quality["recommended_first_share"] == 1.0 and quality["asks_per_task"] == 3.0


def test_a_clarify_call_with_yes_no_is_bare_and_with_concrete_choices_is_not():
    def clarify(choices):
        return MinedSession("alpha", WEEK_2026_W10, (
            Message("user", "x", WEEK_2026_W10), Message("assistant", "Details sent.", WEEK_2026_W10 + 1, (AskItem("Send?", choices),)),
            Message("user", "ok", WEEK_2026_W10 + 2), Message("assistant", "Sent.", WEEK_2026_W10 + 3)))

    bare = total(mining.mine({"alpha": ListSource(clarify(("Yes", "No")))}))["ask_quality"]
    concrete = total(mining.mine({"alpha": ListSource(clarify(("Send as written", "Edit then send")))}))["ask_quality"]
    assert bare["bare_yes_no_share"] == 1.0 and concrete["bare_yes_no_share"] == 0.0


def test_a_turn_with_two_questions_counts_as_batched():
    session = MinedSession("alpha", WEEK_2026_W10, (
        Message("user", "x", WEEK_2026_W10),
        Message("assistant", "Two things.", WEEK_2026_W10 + 1, (AskItem("Budget?"), AskItem("Deadline?"))),
        Message("user", "a, b", WEEK_2026_W10 + 2), Message("assistant", "Ok.", WEEK_2026_W10 + 3)))
    assert total(mining.mine({"alpha": ListSource(session)}))["ask_quality"]["batched_turn_share"] == 1.0


def test_handbacks_corrections_rate_and_owner_tokens_are_counts_only():
    session = convo(("user", "fix the build"), ("assistant", "Please run the following command in your terminal."),
                    ("user", "just do it, you can run it yourself"), ("assistant", "Done."))
    stats = total(mining.mine({"alpha": ListSource(session)}))
    assert stats["handbacks"] == 1
    assert stats["owner_corrections_per_100_turns"] == 50.0
    assert stats["owner_tokens_per_task"] > 0


def test_reach_log_rows_become_acted_share_counts_without_titles():
    rows = [{"created_at": WEEK_2026_W10, "domain": "cron", "status": "alerted", "outcome": "acted", "title": "secret title"},
            {"created_at": WEEK_2026_W10 + 5, "domain": "cron", "status": "alerted", "outcome": "dismissed", "title": "x"},
            {"created_at": WEEK_2026_W10 + 9, "domain": "suggestions", "status": "landed_silent", "outcome": None}]
    report = mining.count_reach(rows)
    assert report["acted_share"] == 0.5
    assert report["weeks"]["2026-W10"]["cron"]["offers"] == 2
    assert "secret title" not in json.dumps(report)


def test_the_reach_command_reads_a_log_file(tmp_path, capsys):
    log = tmp_path / "offers.json"
    log.write_text(json.dumps([{"created_at": WEEK_2026_W10, "domain": "cron", "status": "alerted", "outcome": "acted"}]))
    assert cli.main(["reach", str(log)]) == 0
    assert "acted share: 1.0" in capsys.readouterr().out


def test_a_free_text_clarify_question_with_a_default_is_not_a_bare_open_question():
    def mined(question):
        call = {"function": {"name": "clarify", "arguments": json.dumps({"questions": [question]})}}
        return total(mining.mine({"alpha": ListSource(MinedSession("alpha", WEEK_2026_W10, (
            Message("user", "x", WEEK_2026_W10),
            Message("assistant", "Details sent.", WEEK_2026_W10 + 1, mining._clarify_asks([call])),
            Message("user", "ok", WEEK_2026_W10 + 2), Message("assistant", "Ok.", WEEK_2026_W10 + 3))))}))["ask_quality"]

    assert mined({"question": "Bot name?", "default": "Pal"})["no_options_no_default_share"] == 0.0
    assert mined({"question": "Bot name?"})["no_options_no_default_share"] == 1.0


def commitment_call(action="promise"):
    return {"id": "c9", "type": "function",
            "function": {"name": "commitment", "arguments": json.dumps({"action": action, "text": "watch CI"})}}


def test_chases_and_promises_without_a_commitment_event_in_the_same_turn_are_counted():
    start = WEEK_2026_W10
    session = MinedSession("alpha", start, (
        Message("user", "draft the note", start),
        Message("assistant", "Draft ready. I'll check back tomorrow.", start + 1),
        Message("user", "xong chưa?", start + 2),
        Message("assistant", "Recording it.", start + 3, records_commitment=True),
        Message("assistant", "I'll follow up when CI is green.", start + 4),
        Message("user", "any update?", start + 5),
        Message("assistant", "I'll let you know.", start + 6, records_commitment=False),
    ))
    stats = total(mining.mine({"alpha": ListSource(session)}))
    assert stats["owner_chases"] == 2
    assert (stats["promise_turns"], stats["unrecorded_promises"]) == (3, 2)


def test_the_store_source_sees_a_commitment_event_but_not_a_commitment_list(tmp_path):
    with open_persistence(profile_scope(home=tmp_path), eager=True) as writer:
        seed_session(writer, "s1", "telegram")
        seed_messages(writer, "s1", {"role": "user", "content": "watch the deploy"},
                      {"role": "assistant", "content": "On it.", "tool_calls": [commitment_call()]},
                      {"role": "assistant", "content": "I'll let you know when it is live."},
                      {"role": "user", "content": "any update?"},
                      {"role": "assistant", "content": "Checking.", "tool_calls": [commitment_call("list")]},
                      {"role": "assistant", "content": "I'll report back soon."})
    stats = total(mining.mine({"alpha": mining.PersistenceSource(tmp_path, bot="alpha")}))
    assert (stats["promise_turns"], stats["unrecorded_promises"], stats["owner_chases"]) == (2, 1, 1)


DELEGATED = ({"id": "c1", "type": "function",
              "function": {"name": "delegate_task", "arguments": "{\"background\": true}"}},)


def bot_chat_stats(tmp_path, window=BOT_CHAT_WINDOW, **seed):
    seed_bot_chat(tmp_path, **seed)
    return mining.tally(mining.PersistenceSource(tmp_path, bot="alpha"), since=window[0], until=window[1])


def test_a_long_lived_bot_chat_is_counted_for_the_window_its_messages_fall_in(tmp_path):
    stats = bot_chat_stats(tmp_path)
    assert (stats.sessions, stats.owner_turns, stats.assistant_turns, stats.question_turns) == (1, 3, 3, 1)
    assert stats.promise_turns >= 1 and stats.unrecorded_promises >= 1


def test_messages_before_the_window_are_not_counted_and_the_week_is_the_in_window_one(tmp_path):
    seed_bot_chat(tmp_path)
    since, until = BOT_CHAT_WINDOW
    report = mining.mine({"alpha": mining.PersistenceSource(tmp_path, bot="alpha")}, since=since, until=until)
    in_window = mining._week_key(NOW - 18 * DAY)
    assert list(report["bots"]["alpha"]["weeks"]) == [in_window]
    assert mining._week_key(NOW - 18 * DAY - 264 * HOUR) != in_window
    assert total(report)["owner_turns"] == 3


def test_a_window_holding_no_message_of_the_session_counts_no_session(tmp_path):
    stats = bot_chat_stats(tmp_path, (NOW - 60 * DAY, NOW - 50 * DAY))
    assert stats.sessions == 0


def test_a_background_delegation_in_a_promise_turn_counts_as_recorded(tmp_path):
    stats = bot_chat_stats(tmp_path, extra_calls=DELEGATED)
    assert (stats.promise_turns, stats.unrecorded_promises) == (1, 0)
