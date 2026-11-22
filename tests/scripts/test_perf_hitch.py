"""apps/ios/Tools/perf/perf_hitch.py: hitch report validation, summary maths, compare table, PAL_HITCH capture parsing."""

import importlib.util
import json
import math
import subprocess
import sys
from pathlib import Path

import pytest

PERF_DIR = Path(__file__).resolve().parents[2] / "apps" / "ios" / "Tools" / "perf"


def _load(name):
    spec = importlib.util.spec_from_file_location(name, PERF_DIR / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


perf_hitch = _load("perf_hitch")


def report(**overrides):
    base = {
        "schema": 2, "platform": "macOS", "startedAt": "2026-11-18T09:30:00Z", "durationSeconds": 30.0,
        "frames": 1800, "hitches": 15, "severeHitches": 3, "worstFrameMs": 52.4, "hitchMs": 90.0, "budgetMs": 16.7,
        "thresholdsMs": {"hitch": 25.05, "severe": 33.0},
    }
    return {**base, **overrides}


def with_long(**overrides):
    base = {
        "severeHitches": 3,
        "worstFrameMs": 547.0,
        "longHitchThresholdMs": 100.0,
        "longHitchCount": 2,
        "longHitches": [{"atSeconds": 7.25, "ms": 120.0}, {"atSeconds": 42.5, "ms": 547.0}],
    }
    return report(**{**base, **overrides})


def without(field):
    return {key: value for key, value in report().items() if key != field}


def test_summary_rates_are_per_minute_and_hitch_time_is_per_second():
    stats = perf_hitch.summary(report())
    assert stats["hitchesPerMinute"] == pytest.approx(30.0)
    assert stats["severePerMinute"] == pytest.approx(6.0)
    assert stats["hitchMsPerSecond"] == pytest.approx(3.0)
    assert stats["worstFrameMs"] == 52.4


def test_summary_scales_with_duration():
    short = perf_hitch.summary(report(durationSeconds=30.0))
    long = perf_hitch.summary(report(durationSeconds=120.0))
    assert long["hitchesPerMinute"] == pytest.approx(short["hitchesPerMinute"] / 4)
    assert long["hitchMsPerSecond"] == pytest.approx(short["hitchMsPerSecond"] / 4)


def test_render_summary_names_every_headline_number():
    text = perf_hitch.render_summary(report())
    assert "30.00/min" in text
    assert "6.00/min" in text
    assert "3.00 ms per second" in text
    assert "52.4 ms" in text


def test_a_report_without_long_hitch_fields_still_validates_and_prints_no_long_section():
    assert perf_hitch.validate(report()) == report()
    assert "long hitches" not in perf_hitch.render_summary(report())


def test_summary_lists_the_longest_hitches_worst_first_with_their_time():
    text = perf_hitch.render_summary(with_long())
    assert "long hitches (> 100 ms): 2" in text
    lines = [line.strip() for line in text.splitlines() if line.strip().startswith("t=")]
    assert lines == ["t=42.50 s  547.0 ms", "t=7.25 s  120.0 ms"]
    assert perf_hitch.summary(with_long())["longestHitches"][0] == {"atSeconds": 42.5, "ms": 547.0}


def test_summary_lists_at_most_ten_even_if_the_file_holds_more():
    many = [{"atSeconds": float(i), "ms": 100.0 + i} for i in range(1, 13)]
    stats = perf_hitch.summary(with_long(longHitchCount=12, severeHitches=12, hitches=12, worstFrameMs=112.0, longHitches=many[:10]))
    assert len(stats["longestHitches"]) == 10
    assert stats["longestHitches"][0]["ms"] == 110.0


@pytest.mark.parametrize(
    ("bad", "fragment"),
    [
        (with_long(longHitchCount=-1), "longHitchCount"),
        (with_long(longHitchCount=2.5), "longHitchCount"),
        (with_long(longHitchCount=1), "lists 2 entries"),
        (with_long(longHitchCount=4, severeHitches=3), "exceeds severeHitches"),
        (with_long(longHitches="none"), "must be a list"),
        (with_long(longHitches=[1]), "must be objects"),
        (with_long(longHitches=[{"atSeconds": 1.0}]), "ms"),
        (with_long(longHitches=[{"atSeconds": -1.0, "ms": 120.0}]), "atSeconds"),
        (with_long(longHitches=[{"atSeconds": 1.0, "ms": 900.0}]), "worstFrameMs"),
        ({key: value for key, value in with_long().items() if key != "longHitches"}, "come together"),
    ],
)
def test_malformed_long_hitch_fields_are_rejected(bad, fragment):
    with pytest.raises(perf_hitch.HitchReportError, match=fragment):
        perf_hitch.validate(bad)


def test_cli_prints_the_longest_hitches_from_a_stdout_capture(tmp_path):
    capture = tmp_path / "stdout.txt"
    capture.write_text(stdout_capture(with_long()))
    result = run_cli(capture)
    assert result.returncode == 0
    assert "t=42.50 s  547.0 ms" in result.stdout


def row_cells(table, metric):
    line = next(line for line in table.splitlines() if line.startswith(metric))
    return line.split()[1:]


def test_compare_table_reports_before_after_and_percent_change():
    after = report(hitches=6, severeHitches=0, hitchMs=30.0, worstFrameMs=26.2)
    table = perf_hitch.compare(report(), after)
    assert table.splitlines()[0].split() == ["metric", "before", "after", "change"]
    assert row_cells(table, "hitches_per_min") == ["30.00", "12.00", "-60.0%"]
    assert row_cells(table, "hitch_ms_per_s") == ["3.00", "1.00", "-66.7%"]
    assert row_cells(table, "worst_frame_ms") == ["52.4", "26.2", "-50.0%"]
    assert row_cells(table, "severe_per_min")[2] == "-100.0%"


def test_compare_marks_a_regression_from_zero_instead_of_hiding_it():
    clean = report(hitches=0, severeHitches=0, hitchMs=0.0)
    assert row_cells(perf_hitch.compare(clean, report()), "hitches_per_min")[2] == "n/a"
    assert row_cells(perf_hitch.compare(clean, clean), "hitches_per_min")[2] == "+0.0%"


def test_compare_warns_when_frame_budgets_differ():
    assert "frame budgets differ" in perf_hitch.compare(report(), report(budgetMs=8.33))
    assert "frame budgets differ" not in perf_hitch.compare(report(), report())


def test_summary_text_names_the_frame_budget():
    assert "frame budget 8.33 ms" in perf_hitch.render_summary(report(budgetMs=8.33))


def test_compare_warns_when_platforms_differ():
    assert "platforms differ" in perf_hitch.compare(report(), report(platform="iOS"))
    assert "platforms differ" not in perf_hitch.compare(report(), report())


@pytest.mark.parametrize(
    ("bad", "fragment"),
    [
        (report(schema=1), "schema"),
        (report(schema=3), "schema"),
        (without("budgetMs"), "budgetMs"),
        (report(budgetMs=0), "budgetMs"),
        (report(budgetMs=-8.3), "budgetMs"),
        (without("schema"), "schema"),
        (report(schema=True), "schema"),
        (report(platform="tvOS"), "platform"),
        (without("startedAt"), "startedAt"),
        (report(startedAt="yesterday"), "startedAt"),
        (without("frames"), "frames"),
        (without("hitchMs"), "hitchMs"),
        (without("thresholdsMs"), "thresholdsMs"),
        (report(thresholdsMs={"hitch": 25.05}), "severe"),
        (report(hitches=-1), "hitches"),
        (report(worstFrameMs=-0.5), "worstFrameMs"),
        (report(hitchMs=-3.0), "hitchMs"),
        (report(frames=1.5), "frames"),
        (report(hitches="15"), "hitches"),
        (report(hitchMs=math.nan), "hitchMs"),
        (report(durationSeconds=0), "durationSeconds"),
        (report(severeHitches=16), "severeHitches"),
        (report(frames=10), "hitches"),
        ([report()], "object"),
    ],
)
def test_invalid_reports_are_rejected_with_the_offending_field(bad, fragment):
    with pytest.raises(perf_hitch.HitchReportError, match=fragment):
        perf_hitch.validate(bad)


def test_a_valid_report_passes_unchanged():
    assert perf_hitch.validate(report()) == report()


def stdout_capture(*reports):
    noise = ["2026-11-18 09:30:00 Pal[123] launching", "[PalPerf] enabled"]
    lines = noise + [f"PAL_HITCH {json.dumps(item)}" for item in reports] + ["Pal exited"]
    return "\n".join(lines) + "\n"


def test_parse_reads_a_json_report():
    assert perf_hitch.parse(json.dumps(report(), indent=2)) == report()


def test_parse_extracts_the_pal_hitch_line_from_a_stdout_capture():
    assert perf_hitch.parse(stdout_capture(report())) == report()


def test_parse_uses_the_last_pal_hitch_line_of_a_capture():
    last = report(hitches=4, severeHitches=1)
    assert perf_hitch.parse(stdout_capture(report(), last)) == last


def test_parse_validates_what_it_extracts():
    with pytest.raises(perf_hitch.HitchReportError, match="schema"):
        perf_hitch.parse(stdout_capture(report(schema=9)))


@pytest.mark.parametrize("text", ["", "no report here\nPAL_HITCH\n", "PAL_HITCH not-json\n"])
def test_parse_rejects_text_without_a_usable_report(text):
    with pytest.raises(perf_hitch.HitchReportError):
        perf_hitch.parse(text)


def test_load_accepts_json_file_and_stdout_capture_alike(tmp_path):
    as_json = tmp_path / "pal-hitch.json"
    as_json.write_text(json.dumps(report()))
    as_capture = tmp_path / "stdout.txt"
    as_capture.write_text(stdout_capture(report()))
    assert perf_hitch.load(as_json) == perf_hitch.load(as_capture)


def test_load_errors_name_the_file(tmp_path):
    bad = tmp_path / "bad.json"
    bad.write_text(json.dumps(report(schema=3)))
    with pytest.raises(perf_hitch.HitchReportError, match="bad.json"):
        perf_hitch.load(bad)
    with pytest.raises(perf_hitch.HitchReportError, match="missing.json"):
        perf_hitch.load(tmp_path / "missing.json")


def run_cli(*args):
    return subprocess.run([sys.executable, str(PERF_DIR / "perf.py"), "hitch", *map(str, args)], capture_output=True, text=True, check=False, timeout=60)


def test_cli_prints_a_summary_and_a_comparison(tmp_path):
    before, after = tmp_path / "before.json", tmp_path / "after.txt"
    before.write_text(json.dumps(report()))
    after.write_text(stdout_capture(report(hitches=6)))
    summary = run_cli(before)
    assert summary.returncode == 0
    assert "30.00/min" in summary.stdout
    comparison = run_cli(before, after)
    assert comparison.returncode == 0
    assert "-60.0%" in comparison.stdout


def test_cli_rejects_a_bad_report_with_a_clear_error(tmp_path):
    bad = tmp_path / "bad.json"
    bad.write_text(json.dumps(report(hitches=-4)))
    result = run_cli(bad)
    assert result.returncode == 2
    assert "hitches" in result.stderr
    assert result.stdout == ""
