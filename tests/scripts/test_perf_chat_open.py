"""apps/ios/Tools/perf/perf_chat_open.py: pal-chat-open.jsonl traces to the chat-open report."""

import importlib.util
import json
import sys
from pathlib import Path

import pytest

PERF_DIR = Path(__file__).resolve().parents[2] / "apps" / "ios" / "Tools" / "perf"
sys.path.insert(0, str(PERF_DIR))


def _load(name):
    spec = importlib.util.spec_from_file_location(name, PERF_DIR / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


perf_chat_open = _load("perf_chat_open")


def record(bot, step, ms, open_count, cached=None, gateway=None, rows=None, detail=None):
    return {"bot": bot, "step": step, "ms": ms, "open": open_count, "cachedSeq": cached, "gatewaySeq": gateway, "rows": rows, "detail": detail}


COLD_STALE = [
    record("alpha", "open.tap", 0, 1),
    record("alpha", "cache.load.begin", 2, 1),
    record("alpha", "cache.load.end", 40, 1, cached=100, rows=200),
    record("alpha", "cache.frame", 55, 1, cached=100, rows=200),
    record("alpha", "connect.begin", 56, 1),
    record("alpha", "connect.end", 180, 1),
    record("alpha", "resolve.end", 200, 1, gateway=130),
    record("alpha", "page.adopted", 260, 1, gateway=130),
    record("alpha", "live", 270, 1),
    record("alpha", "frame.newest", 300, 1, gateway=130, rows=230),
]
WARM = [
    record("alpha", "open.tap", 0, 2),
    record("alpha", "cache.frame", 8, 2, cached=130, gateway=130),
    record("alpha", "syncing", 9, 2),
    record("alpha", "frame.newest", 120, 2, cached=130, gateway=130),
    record("alpha", "session.warm", 125, 2),
]
SLOW_SYNCED = [
    record("beta", "open.tap", 0, 1),
    record("beta", "syncing", 20, 1),
    record("beta", "frame.newest", 400, 1),
]


def write(path, records):
    path.write_text("\n".join(json.dumps(item) for item in records) + "\n", encoding="utf-8")
    return path


def test_cold_stale_open_is_flagged_without_a_syncing_step(tmp_path):
    result = perf_chat_open.collect(perf_chat_open.load([write(tmp_path / "pal-chat-open.jsonl", COLD_STALE)]))
    [entry] = result["opens"]
    assert (entry["cacheFrameMs"], entry["newestFrameMs"]) == (55, 300)
    assert entry["stale"] and entry["seqGap"] == 30
    assert result["stale"]["opens"] == 1 and result["stale"]["gap"]["max"] == 30
    assert result["slowWithoutSyncing"] == ["alpha#1"]


def test_warm_open_with_syncing_before_a_late_frame_is_not_flagged(tmp_path):
    result = perf_chat_open.collect(perf_chat_open.load([write(tmp_path / "pal-chat-open.jsonl", WARM + SLOW_SYNCED)]))
    by_open = {(entry["bot"], entry["open"]): entry for entry in result["opens"]}
    assert not by_open[("alpha", 2)]["stale"] and not by_open[("alpha", 2)]["slowWithoutSyncing"]
    assert by_open[("beta", 1)]["newestFrameMs"] == 400 and not by_open[("beta", 1)]["slowWithoutSyncing"]
    assert result["stale"]["opens"] == 0 and result["slowWithoutSyncing"] == []


def test_step_percentiles_are_taken_over_opens(tmp_path):
    result = perf_chat_open.collect(perf_chat_open.load([write(tmp_path / "pal-chat-open.jsonl", COLD_STALE + WARM)]))
    newest = result["steps"]["frame.newest"]
    assert (newest["n"], newest["p50"], newest["p95"], newest["max"]) == (2, 120, 300, 300)
    assert list(result["steps"]).index("cache.frame") < list(result["steps"]).index("frame.newest")


def test_text_report_names_each_open_and_the_stale_count(tmp_path):
    path = write(tmp_path / "pal-chat-open.jsonl", COLD_STALE + WARM)
    text = perf_chat_open.render([path])
    assert "stale cache: 1 of 2 opens" in text and "alpha#1" in text and "100->130" in text and "NO-SYNCING" in text


def test_directory_argument_and_environment_default_find_the_trace(tmp_path, monkeypatch):
    write(tmp_path / "pal-chat-open.jsonl", WARM)
    assert perf_chat_open.render([tmp_path]) == perf_chat_open.render([tmp_path / "pal-chat-open.jsonl"])
    monkeypatch.setenv("PAL_PERF_DIR", str(tmp_path))
    assert perf_chat_open.render([]) == perf_chat_open.render([tmp_path])


def test_json_output_round_trips(tmp_path, capsys):
    path = write(tmp_path / "pal-chat-open.jsonl", COLD_STALE)
    assert perf_chat_open.main([str(path), "--json"]) == 0
    printed = json.loads(capsys.readouterr().out)
    assert printed["stale"]["opens"] == 1 and printed["opens"][0]["bot"] == "alpha"


def test_malformed_line_names_file_and_line_and_exits_nonzero(tmp_path, capsys):
    path = tmp_path / "pal-chat-open.jsonl"
    path.write_text(json.dumps(WARM[0]) + "\n{not json\n", encoding="utf-8")
    assert perf_chat_open.main([str(path)]) == 2
    assert f"{path}:2" in capsys.readouterr().err


@pytest.mark.parametrize("bad", [
    {"bot": "a", "step": "live", "ms": "12", "open": 1},
    {"bot": "a", "step": "live", "ms": 12, "open": 1.5},
    {"bot": "a", "step": "live", "ms": 12, "open": 1, "cachedSeq": "x"},
    {"bot": 3, "step": "live", "ms": 12, "open": 1},
    [1, 2],
])
def test_wrongly_typed_record_is_rejected(tmp_path, bad):
    path = write(tmp_path / "pal-chat-open.jsonl", [bad])
    with pytest.raises(perf_chat_open.ChatOpenError):
        perf_chat_open.load([path])


def test_empty_missing_and_unset_inputs_exit_nonzero(tmp_path, capsys, monkeypatch):
    empty = tmp_path / "pal-chat-open.jsonl"
    empty.write_text("\n", encoding="utf-8")
    assert perf_chat_open.main([str(empty)]) == 2
    assert "no chat-open records" in capsys.readouterr().err
    assert perf_chat_open.main([str(tmp_path / "absent.jsonl")]) == 2
    assert "cannot read" in capsys.readouterr().err
    monkeypatch.delenv("PAL_PERF_DIR", raising=False)
    assert perf_chat_open.main([]) == 2
    assert "PAL_PERF_DIR" in capsys.readouterr().err
