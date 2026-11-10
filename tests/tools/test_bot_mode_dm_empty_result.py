"""A bot-to-bot delivery always ends with something the sender can use: the reply, a plain status, or
an explicit "no output" line that names the delivery. Never a blank completion (the runner's guard,
the completion notification, the plain-sentence outcomes) and the wording the receiving bot is given."""

import io
import json
import shlex
import threading
from contextlib import redirect_stdout
from types import SimpleNamespace

import pytest

from agent import bot_chain
from gateway.bot_loop_guard import BotLoopGuardSettings
from gateway.run_notifications import GatewayNotificationsMixin
from tools import bot_mode_dm, bot_mode_probe
from tools.bot_mode_dm_outcome import outcome_line
from tools.process_registry_notifications import format_process_notification

from tests.tools.test_bot_mode_dm import _admitted_live_dm, _fresh_probe_cache, _managed_home


def _run_main(args) -> tuple[int, dict]:
    out = io.StringIO()
    with redirect_stdout(out):
        code = bot_mode_dm._delivery_main(args)
    return code, json.loads(out.getvalue().strip().splitlines()[-1])


def _notification(output: str, command: str = "python tools/bot_mode_dm.py --run-delivery") -> str:
    session = SimpleNamespace(output_buffer=output, command=command, exit_code=0, task_id="",
                              owner_task_id="", started_at=1.0, parent_session_id="")
    event = GatewayNotificationsMixin._build_process_completion_event({}, session, "proc_abc123abc123")
    return format_process_notification(event)


def test_a_long_reply_reaches_the_sender_with_its_status(tmp_path, monkeypatch):
    _live, authority, record = _admitted_live_dm(tmp_path, monkeypatch, "c" * 32)
    authority.settle(record["delivery_id"], status="settled", reply="long reply with `code` and **bold**. " * 150)
    out = io.StringIO()
    with redirect_stdout(out):
        assert bot_mode_dm._wait_live_dm(str(tmp_path), record["delivery_id"]) == 0

    text = _notification(out.getvalue())

    assert "showing last 0 chars" not in text
    assert '"status": "settled"' in text and record["delivery_id"] in text


def test_a_target_still_working_at_the_deadline_says_pending_and_do_not_resend(tmp_path, monkeypatch):
    _live, _authority, record = _admitted_live_dm(tmp_path, monkeypatch, "d" * 32)
    monkeypatch.setattr(bot_mode_dm, "_LIVE_WAIT_MAX_SECONDS", 0.1)
    monkeypatch.setattr(bot_mode_dm, "_live_target_state", lambda _file: "working")
    out = io.StringIO()
    with redirect_stdout(out):
        bot_mode_dm._wait_live_dm(str(tmp_path), record["delivery_id"])

    text = _notification(out.getvalue())

    assert "its turn is still running" in text and "do not resend" in text and record["delivery_id"] in text


def test_a_reply_after_the_wait_window_still_reaches_the_sender(tmp_path, monkeypatch):
    _live, authority, record = _admitted_live_dm(tmp_path, monkeypatch, "e" * 32)
    threading.Timer(0.05, lambda: authority.settle(record["delivery_id"], status="settled", reply="late")).start()
    out = io.StringIO()
    with redirect_stdout(out):
        bot_mode_dm._wait_live_dm(str(tmp_path), record["delivery_id"])

    assert json.loads(out.getvalue())["reply"] == "late"


def test_an_empty_reply_says_the_turn_ended_with_no_reply():
    line = outcome_line("@bot", {"status": "settled", "reply": ""})

    assert line == ("@bot finished its turn with no reply text (turn ended with no reply). The request was "
                    "received; do not resend it. Tell your user, and message them again only with something new.")


def test_empty_stdout_from_a_delivery_names_the_delivery_and_forbids_resending(tmp_path):
    dm_file = tmp_path / "dm-x.txt"
    command = shlex.join(["python", "tools/bot_mode_dm.py", "--run-delivery", "query-file", str(dm_file), "hermes", "-p", "ops"])

    text = _notification("", command)

    assert "Output:\n(no output was captured from this message_agent delivery process" in text
    assert bot_mode_dm._dm_delivery_id(dm_file) in text and "Do not resend" in text


@pytest.mark.parametrize("output", ["", "  \n"])
def test_empty_stdout_from_any_process_is_said_plainly(output):
    text = _notification(output, "true")

    assert "Output:\n(no output was captured: the process printed nothing before it ended)" in text


@pytest.mark.parametrize("args, expected", [
    (["--run-delivery"], "failed"),
    (["--run-delivery", "--author", "not json", "query-file", "/tmp/dm-y.txt", "hermes", "-p", "ghost"], "failed"),
])
def test_runner_refusals_before_admission_print_a_status(args, expected):
    code, payload = _run_main(args)

    assert code == 2 and payload["status"] == expected and "delivery_id" in payload


def test_a_runner_crash_prints_status_and_delivery_id(tmp_path, monkeypatch):
    dm_file = tmp_path / "dm-z.txt"
    dm_file.write_text("x", encoding="utf-8")

    def boom(*_a, **_k):
        raise RuntimeError("boom")

    monkeypatch.setattr(bot_mode_dm, "_run_delivery", boom)
    code, payload = _run_main(["--run-delivery", "query-file", str(dm_file), "hermes", "-p", "ops"])

    assert code == 1 and payload["error"] == "boom"
    assert payload["status"] == "failed" and payload["delivery_id"] == bot_mode_dm._dm_delivery_id(dm_file)


def test_a_runner_that_returns_silent_after_admission_prints_an_unknown_outcome(tmp_path, monkeypatch):
    dm_file = tmp_path / "dm-q.txt"
    dm_file.write_text("x", encoding="utf-8")
    (tmp_path / "dm-q.txt.live.json").write_text("{}", encoding="utf-8")
    monkeypatch.setattr(bot_mode_dm, "_run_delivery", lambda *a, **k: 0)

    code, payload = _run_main(["--run-delivery", "query-file", str(dm_file), "hermes", "-p", "ops"])

    assert code == 0 and payload["status"] == "ambiguous" and "Do not resend" in payload["detail"]
    assert payload["delivery_id"] == bot_mode_dm._dm_delivery_id(dm_file)


def test_tool_description_pins_the_receiving_rule_and_the_snapshot_caveat():
    description = bot_mode_dm.message_agent_tool_schema()["function"]["description"]

    assert ("When YOU receive such a message: your first output is ONE short line to your owner saying what you "
            "received and what you will do; your final text is the reply to the sender; do NOT call "
            "message_agent to answer it (that spends a hop of the max_hops limit).") in description
    assert "target_state in the ack is a snapshot taken at hand-off: 'idle' can mean the turn has not started yet" in description


def test_protocol_section_pins_the_receiving_rule(tmp_path):
    section = bot_mode_probe.get_bot_mode_protocol_section(_managed_home(tmp_path), force_refresh=True)

    assert ("your first output is ONE short line to your owner saying what you received and what you will do; "
            "then return your concise, substantive reply as this turn's final response, which is the reply to "
            "the sender.") in section
    assert "each message_agent call spends a hop of the max_hops limit" in section


class _Bot(SimpleNamespace):
    def _emit_notice(self, notice):
        self.notices.append(notice)

    def _emit_notice_clear(self, key):
        self.notices.append(("clear", key))


def _agent():
    return _Bot(session_id="s1", notices=[], _turn_author=None)


def test_a_bot_authored_turn_shows_taking_this_and_clears_when_it_ends():
    agent = _agent()
    author = {"id": "bot:alpha", "name": "alpha", "is_bot": True}

    bot_chain.announce_bot_turn(agent, author, "Message from 🤖 alpha (@alpha): update the changelog\n\nConstraints: short")
    bot_chain.clear_bot_turn(agent)

    assert agent.notices[0].text == "taking this: update the changelog" and agent.notices[0].kind == "sticky"
    assert agent.notices[1] == ("clear", bot_chain.BOT_TURN_NOTICE_KEY)


def test_an_unstamped_bot_turn_says_working_and_a_human_turn_says_nothing():
    agent = _agent()
    bot_chain.announce_bot_turn(agent, {"id": "bot:alpha", "is_bot": True}, "no stamp here")
    bot_chain.announce_bot_turn(agent, {"id": "user:me", "is_bot": False}, "hi")
    bot_chain.announce_bot_turn(agent, None, "hi")
    bot_chain.clear_bot_turn(_agent())

    assert [n.text for n in agent.notices] == ["working"]


def test_the_working_line_and_a_final_answer_spend_no_hop(monkeypatch):
    monkeypatch.setattr(bot_chain, "_CHAINS", {})
    monkeypatch.setattr(bot_chain, "_settings", lambda: BotLoopGuardSettings(max_hops=4))
    agent = _agent()
    author = {"id": "bot:alpha", "name": "alpha", "is_bot": True}

    bot_chain.on_turn_start(agent, author, None, "Message from 🤖 alpha (@alpha): hi")
    before = dict(bot_chain._CHAINS["s1"])
    bot_chain.announce_bot_turn(agent, author, "Message from 🤖 alpha (@alpha): hi")
    bot_chain.clear_bot_turn(agent)

    assert {k: bot_chain._CHAINS["s1"][k] for k in ("hops", "sent")} == {k: before[k] for k in ("hops", "sent")}
    assert bot_chain.admit_send(agent, ["bot:beta"], "separate follow-up").hop == before["hops"] + 1
