"""apps/ios/Tools/perf/perf_mac_scenario.py and the fixture pieces it drives: stub_llm's stream trigger and seed_parity's roster size."""

import importlib.util
import re
from pathlib import Path

import pytest

IOS_DIR = Path(__file__).resolve().parents[2] / "apps" / "ios"
INTERVALS = (
    "roster.apply", "roster.refetch", "chat.rebuild", "chat.timeline.apply", "markdown.parse",
    "avatar.frame", "shell.body", "disk.cache.load", "disk.sync.main",
)
TEMPLATES = ("Time Profiler", "SwiftUI", "Animation Hitches")


def _load(name, relative):
    spec = importlib.util.spec_from_file_location(name, IOS_DIR / relative)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


scenario = _load("perf_mac_scenario_under_test", "Tools/perf/perf_mac_scenario.py")
stub = _load("stub_llm_under_test", "Tools/stub-llm/stub_llm.py")
seeder = _load("seed_parity_under_test", "Tools/seed-parity/seed_parity.py")


def chat_request(text):
    return {"tools": [{"function": {"name": "terminal"}}], "messages": [{"role": "user", "content": text}]}


def test_stub_streams_a_long_markdown_reply_for_the_trigger_only():
    kind, pieces, delay = stub.plan(chat_request(f"please {stub.STREAM_MARKDOWN_TRIGGER}"))
    reply = "".join(pieces)
    assert kind == "text"
    assert len(pieces) > 2000
    assert delay > 0
    assert re.search(r"^# ", reply, re.MULTILINE)
    assert re.search(r"^## ", reply, re.MULTILINE)
    assert re.search(r"^- ", reply, re.MULTILINE)
    assert re.search(r"^\d+\. ", reply, re.MULTILINE)
    assert reply.count("```") >= 2 and reply.count("```") % 2 == 0
    _, ordinary, _ = stub.plan(chat_request("hello"))
    assert len(ordinary) < len(pieces) / 10


def test_stub_trigger_does_not_collide_with_other_scripted_triggers():
    trigger = stub.STREAM_MARKDOWN_TRIGGER
    others = [*stub.TOOL_COMMANDS, "HOLD", "SLOW", "CLARIFY", stub.IPHONE_TRIGGER, stub.NARRATED_CLARIFY_TRIGGER, stub.FIXTURE_MCP_TRIGGER]
    assert not [word for word in others if word in trigger]


def test_roster_default_is_the_parity_roster():
    assert seeder.roster() is seeder.BOTS
    assert seeder.slugs() == [bot.slug for bot in seeder.BOTS]


def test_roster_of_twenty_keeps_the_parity_bots_first_and_adds_the_stream_bot():
    bots = seeder.roster(20)
    slugs = seeder.slugs(bots)
    assert len(slugs) == 20
    assert len(set(slugs)) == 20
    assert slugs[: len(seeder.BOTS)] == seeder.slugs()
    assert seeder.STREAM_BOT_SLUG in slugs
    assert all(re.fullmatch(r"[a-z0-9]+(-[a-z0-9]+)*", slug) for slug in slugs)


def test_roster_smaller_than_parity_is_refused():
    with pytest.raises(SystemExit):
        seeder.roster(len(seeder.BOTS) - 1)


def test_steps_name_the_trigger_the_stub_answers_and_the_bot_that_streams():
    text = scenario.steps_text()
    assert stub.STREAM_MARKDOWN_TRIGGER in text
    assert seeder.STREAM_BOT_TITLE in text


def test_steps_cover_the_scenario_with_budgets_that_add_up():
    text = scenario.steps_text()
    for phrase in ("Sign in", "Select roster", "Scroll while streaming", "sidebar divider", "Connect Apps", "Kanban"):
        assert phrase in text
    assert f"{scenario.total_seconds()} s total" in text
    budgets = [int(found) for found in re.findall(r"s, +(\d+) s\]", text)]
    assert len(budgets) == len(scenario.STEPS)
    assert sum(budgets) == scenario.total_seconds()


def test_scroll_step_outlasts_the_stream():
    scroll = next(step for step in scenario.STEPS if "streaming" in step.title)
    assert scroll.seconds >= scenario.stream_seconds()


def test_xtrace_names_every_interval_template_and_the_signpost_source():
    text = scenario.xtrace_text("/Applications/Pal.app", "/work/perf", 170)
    for name in (*INTERVALS, *TEMPLATES):
        assert name in text
    assert "app.pal" in text
    assert "PAL_PERF=1" in text
    assert "--time-limit 170s" in text
    assert "xctrace export" in text and "--toc" in text


def test_xtrace_gives_each_template_its_own_report_and_trace_paths():
    commands = [scenario.record_command(template, "/Applications/Pal.app", "/work/perf", 170) for template in TEMPLATES]
    reports = [re.search(r"PAL_PERF_DIR=(\S+)", command).group(1) for command in commands]
    traces = [re.search(r"--output (\S+)", command).group(1) for command in commands]
    assert len(set(reports)) == len(TEMPLATES)
    assert len(set(traces)) == len(TEMPLATES)
    assert all(trace.startswith(report + "/") for trace, report in zip(traces, reports, strict=True))
    assert all(command.rstrip().endswith("--launch -- /Applications/Pal.app") for command in commands)


def test_xtrace_quotes_paths_with_spaces():
    command = scenario.record_command("Time Profiler", "/Applications/Pal Beta.app", "/work/my perf", 60)
    assert "'/Applications/Pal Beta.app'" in command
    assert "'PAL_PERF_DIR=/work/my perf/time-profiler'" in command


def test_fixture_command_asks_the_e2e_gateway_for_the_twenty_bot_parity_roster():
    command = scenario.fixture_command()
    assert command[0].endswith("Scripts/e2e-gateway")
    assert command[command.index("--seed") + 1] == "parity"
    assert command[command.index("--bots") + 1] == "20"
    assert "--announce" in command


def test_announce_prints_the_connection_details_and_the_trigger():
    environment = {
        "HERMES_IOS_TEST_BASE_URL": "http://127.0.0.1:9999",
        "HERMES_IOS_TEST_USERNAME": "tester",
        "HERMES_IOS_TEST_PASSWORD": "s3cret value",
    }
    text = scenario.announce_text(environment, 20)
    for expected in ("http://127.0.0.1:9999", "tester", "s3cret value", stub.STREAM_MARKDOWN_TRIGGER, "20 bots"):
        assert expected in text
    assert "export HERMES_IOS_TEST_PASSWORD='s3cret value'" in text


def test_fixture_refuses_a_roster_without_the_stream_bot(capsys):
    with pytest.raises(SystemExit) as raised:
        scenario.main(["fixture", "--bots", str(len(seeder.BOTS))])
    assert raised.value.code == 2
    assert "at least" in capsys.readouterr().err
