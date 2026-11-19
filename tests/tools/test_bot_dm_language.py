import json
import logging
from types import SimpleNamespace

import pytest

from agent import bot_chain
from gateway.session_bot import _result
from gateway.session_results import admission_result
from tools import bot_mode_dm
from tools.bot_dm_language import COUNTER_FILE, WITHHELD_NOTICE, Screened, english_paragraphs, is_english

from tests.tools.test_bot_mode_dm import _FakeAgent, _canonical_target, _capture_spawn, _fresh_probe_cache, _managed_home
from tests.tools.test_bot_mode_dm_chain import _bot_turn, chains
from tests.tools.test_bot_mode_dm_outcomes import ALPHA, _settled

REAL_REPLY = ("Anh Ben, em đã cập nhật mockup theo hai chỉnh sửa của anh: chữ nhỏ hơn một bậc, icon ở giữa không có nền, "
              "chỉ tô màu bot.\n\nReply for the chief:\n- Same unit: chat-drop-reliable, card t_0f8967d5.")
ENGLISH_BLOCK = "Reply for the chief:\n- Same unit: chat-drop-reliable, card t_0f8967d5."
VIETNAMESE_PROSE = "Em đã cập nhật xong mockup theo chỉnh sửa của anh, chữ nhỏ hơn một bậc và không có nền."
ENGLISH_PROSE = "The mockup now follows both edits: smaller type and an icon without a background."
SPANISH = ("El equipo ha terminado la revisión del diseño y ahora necesitamos que alguien confirme los cambios antes de "
           "publicar la versión final porque todavía quedan algunos detalles pendientes por resolver con calma.")
FRENCH = ("Nous avons terminé la révision complète du dessin et il faut maintenant que quelqu'un confirme les "
          "modifications avant la publication finale parce que plusieurs détails restent encore à régler ensemble.")


@pytest.mark.parametrize("text", [
    ENGLISH_PROSE,
    f'Owner said (verbatim): "{VIETNAMESE_PROSE}" Please act on it.',
    f"Owner said (verbatim): “{VIETNAMESE_PROSE}” Please act on it.",
    f'Quoting the owner\'s words, "{VIETNAMESE_PROSE}" exactly.',
    f'Owner said (verbatim): "{VIETNAMESE_PROSE}\n\n{VIETNAMESE_PROSE}"',
    f"```\n{VIETNAMESE_PROSE}\n```",
    f"Run `{VIETNAMESE_PROSE}` now.",
    "See https://example.com/đã/cập/nhật and www.example.com/chữ/nhỏ and example.dev/hơn/một.",
    "Edit tools/bot_mode_dm.py, docs\\đã\\cập.md and mockup-đã-cập.png.",
    "Commit 3511e4b and c3511e4b5ebfa750c5d2 landed.",
    "Ping @ben.nguyen and @pal-chief about it.",
    "Cards t_0f8967d5 and PAL-123 are done.",
    "The new venue is in Hà Nội next week.",
])
def test_english_text_passes(text):
    verdict = is_english(text)
    assert verdict.ok, verdict.reason


@pytest.mark.parametrize("text, rule", [
    (VIETNAMESE_PROSE, "a"),
    (f'"{VIETNAMESE_PROSE}"', "a"),
    (f'Owner said (verbatim): {VIETNAMESE_PROSE}', "a"),
    (f'Owner said (verbatim):\n"{VIETNAMESE_PROSE}"', "a"),
    (f'Owner said (verbatim): {"x" * 90} "{VIETNAMESE_PROSE}"', "a"),
    (f"{ENGLISH_PROSE}\n\n{VIETNAMESE_PROSE}", "a"),
    ("Dả xông rồi, cập nhật đã xong.", "a"),
    ("今日は新しいデザインを確認しました。", "b"),
    ("Привет, дизайн готов к проверке.", "b"),
    (SPANISH, "c"),
    (FRENCH, "c"),
])
def test_non_english_text_fails_with_the_rule_that_fired(text, rule):
    verdict = is_english(text)
    assert not verdict.ok and verdict.rule == rule
    assert verdict.reason.startswith(f"rule {rule}:") and 1 <= len(verdict.samples) <= 3


def test_one_vietnamese_word_in_english_text_is_accepted_but_two_are_not():
    assert is_english("Meet at Hà Nội tomorrow.").ok
    assert not is_english("Meet at Hà Nội and Đà Nẵng tomorrow.").ok


def test_short_foreign_runs_below_the_letter_floor_are_accepted():
    assert is_english("Use π and µs here; ok ✅ 🙂.").ok


def test_the_real_reply_is_rejected_whole_and_stripped_to_its_english_block():
    assert not is_english(REAL_REPLY).ok
    stripped = english_paragraphs(REAL_REPLY)
    assert (stripped.text, stripped.dropped, stripped.rule) == (ENGLISH_BLOCK, 1, "a")


def test_paragraph_split_keeps_fenced_blocks_and_marked_quotes_whole():
    text = (f"{ENGLISH_PROSE}\n\n```\n{VIETNAMESE_PROSE}\n\n{VIETNAMESE_PROSE}\n```\n\n"
            f'Owner said (verbatim): "{VIETNAMESE_PROSE}\n\n{VIETNAMESE_PROSE}"')
    assert english_paragraphs(text) == Screened(text)


def _assert_one_drift(home, kind, caplog, *, rule="a"):
    counters = json.loads((home / COUNTER_FILE).read_text())
    assert counters[kind] == 1 and counters["rules"] == {rule: 1}
    lines = [r.getMessage() for r in caplog.records if r.getMessage().startswith("bot-dm-language:")]
    assert len(lines) == 1 and lines[0].startswith(f"bot-dm-language: {kind} from=") and f"rule={rule} dropped=" in lines[0]
    assert VIETNAMESE_PROSE not in lines[0]


def _send(tmp_path, monkeypatch, message, *, expect_admit):
    home = _managed_home(tmp_path, teammates=("researcher", "scribe"))
    _canonical_target(monkeypatch, home / "profiles" / "scribe")
    spawns = _capture_spawn(monkeypatch)
    agent = _FakeAgent(home)
    _bot_turn(agent, "bot:researcher", hops=1)
    before = {key: dict(state) for key, state in bot_chain._CHAINS.items()}
    admitted = []

    def admit(*args, **kwargs):
        admitted.append(args)
        raise AssertionError("admit_send must not run")

    if not expect_admit:
        monkeypatch.setattr(bot_chain, "admit_send", admit)
    raw = bot_mode_dm.message_agent_tool("scribe", message, agent=agent, constraints="", expecting="")
    return home, json.loads(raw), spawns, before, admitted


def test_a_non_english_send_returns_the_error_and_reserves_nothing(tmp_path, monkeypatch, caplog):
    caplog.set_level(logging.WARNING)
    home, ack, spawns, before, admitted = _send(tmp_path, monkeypatch, REAL_REPLY, expect_admit=False)
    assert ack["error"].startswith("bot-to-bot messages must be English; rewrite this message in English "
                                   "(quote the owner verbatim only after 'Owner said (verbatim):'). Rule: rule a:")
    assert not admitted and not spawns and bot_chain._CHAINS == before
    _assert_one_drift(home, "send", caplog)


def test_an_english_send_goes_through(tmp_path, monkeypatch, caplog):
    caplog.set_level(logging.WARNING)
    home, ack, spawns, _before, _admitted = _send(tmp_path, monkeypatch, ENGLISH_BLOCK, expect_admit=True)
    assert not ack.get("error") and spawns
    assert not (home / COUNTER_FILE).exists()


def test_a_marked_owner_quote_in_a_send_goes_through(tmp_path, monkeypatch):
    message = f'Owner said (verbatim): "{VIETNAMESE_PROSE}" Please implement it.'
    _home, ack, spawns, _before, _admitted = _send(tmp_path, monkeypatch, message, expect_admit=True)
    assert not ack.get("error") and spawns


def _reply(tmp_path, final, messages=None, author=ALPHA):
    db, record = _settled(tmp_path, messages or [{"role": "assistant", "content": final}], final, author=author)
    return db, record, SimpleNamespace(persistence=db, db=db)


def test_a_mixed_reply_delivers_only_its_english_paragraphs_and_counts_once(tmp_path, caplog):
    caplog.set_level(logging.WARNING)
    db, record, authority = _reply(tmp_path, REAL_REPLY, [
        {"role": "assistant", "content": "On it.", "tool_calls": [{"function": {"name": "terminal", "arguments": "{}"}}]},
        {"role": "tool", "content": "ok"}, {"role": "assistant", "content": REAL_REPLY}])
    try:
        assert _result(authority, record)["reply"] == ENGLISH_BLOCK
        record.update(_result(authority, record))
        assert _result(authority, record)["reply"] == ENGLISH_BLOCK
        assert "Anh Ben" in admission_result(db, record["admission_id"])["result"]["final_response"]
    finally:
        db.close()
    _assert_one_drift(tmp_path, "reply", caplog)


def test_a_vietnamese_paragraph_after_the_english_one_is_dropped_too(tmp_path):
    final = ENGLISH_BLOCK + "\n\n" + VIETNAMESE_PROSE
    db, record, authority = _reply(tmp_path, final, [
        {"role": "assistant", "content": "x", "tool_calls": [{"function": {"name": "terminal", "arguments": "{}"}}]},
        {"role": "assistant", "content": final}])
    try:
        assert _result(authority, record)["reply"] == ENGLISH_BLOCK
    finally:
        db.close()


def test_an_all_vietnamese_reply_delivers_the_withheld_notice(tmp_path):
    prose = f"{VIETNAMESE_PROSE}\n\n{VIETNAMESE_PROSE} Xong rồi, không còn gì nữa."
    db, record, authority = _reply(tmp_path, prose, [
        {"role": "assistant", "content": "x", "tool_calls": [{"function": {"name": "terminal", "arguments": "{}"}}]},
        {"role": "assistant", "content": prose}])
    try:
        assert _result(authority, record)["reply"] == WITHHELD_NOTICE
    finally:
        db.close()


def test_an_owner_origin_reply_is_untouched(tmp_path):
    db, record, authority = _reply(tmp_path, REAL_REPLY, author=None)
    try:
        assert _result(authority, record)["reply"] == REAL_REPLY
    finally:
        db.close()
    assert not (tmp_path / COUNTER_FILE).exists()
