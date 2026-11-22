"""apps/ios/Tools/perf/perf_tour.py: per-surface frame pacing from a perf-mac-tour run directory."""

import importlib.util
import json
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


perf_tour = _load("perf_tour")

START = 1_800_000_000.0
BUDGET = 8.333


def write_run(directory, phases, frames, cpu=None):
    perf = directory / "perf"
    perf.mkdir(parents=True)
    (perf / "phases.jsonl").write_text("".join(json.dumps(phase) + "\n" for phase in phases))
    rows = "".join(f"{epoch:.6f},{interval:.3f},{budget:.3f}\n" for epoch, interval, budget in frames)
    (perf / "pal-frames.csv").write_text("epoch_s,interval_ms,budget_ms\n" + rows)
    if cpu is not None:
        (directory / "cpu.csv").write_text("epoch_s,pid,cpu_s\n" + "".join(f"{epoch:.3f},1,{seconds:.2f}\n" for epoch, seconds in cpu))


def steady(start, seconds, interval=BUDGET, budget=BUDGET):
    count = int(seconds * 1000 / interval)
    return [(start + index * interval / 1000, interval, budget) for index in range(count)]


def phase(surface, start, end, **extra):
    return {"surface": surface, "startedAt": START + start, "endedAt": START + end, **extra}


def test_a_phase_with_no_frames_is_an_error_not_a_zero_row(tmp_path):
    write_run(tmp_path, [phase("idle", 0, 2), phase("late", 10, 12)], steady(START, 3))
    with pytest.raises(perf_tour.TourError, match="late has zero frames"):
        perf_tour.load_run(tmp_path)


def test_an_empty_phases_file_is_an_error(tmp_path):
    write_run(tmp_path, [], steady(START, 1))
    with pytest.raises(perf_tour.TourError, match="no phases"):
        perf_tour.load_run(tmp_path)


def test_a_missing_frame_log_is_an_error(tmp_path):
    write_run(tmp_path, [phase("idle", 0, 1)], steady(START, 1))
    (tmp_path / "perf" / "pal-frames.csv").unlink()
    with pytest.raises(perf_tour.TourError, match="never wrote its frame log"):
        perf_tour.load_run(tmp_path)


def test_a_run_where_every_phase_was_skipped_is_an_error(tmp_path):
    write_run(tmp_path, [phase("idle", 0, 1, skipped="nothing to do")], steady(START, 1))
    with pytest.raises(perf_tour.TourError, match="every phase"):
        perf_tour.load_run(tmp_path)


def test_a_sixty_hz_frame_on_a_120_hz_display_counts_as_missed(tmp_path):
    frames = steady(START, 1) + [(START + 1.001, 16.7, BUDGET)] + steady(START + 1.02, 1)
    write_run(tmp_path, [phase("scroll", 0, 3)], frames)
    metrics = perf_tour.load_run(tmp_path)["surfaces"]["scroll"]
    assert metrics["missed_pct"] == pytest.approx(100 / metrics["frames"])
    assert metrics["hitch_ms_per_s"] == pytest.approx((16.7 - BUDGET) / 3, rel=1e-3)
    assert metrics["hz"] == pytest.approx(120, abs=0.1)


def test_the_same_frame_is_smooth_on_a_60_hz_display(tmp_path):
    write_run(tmp_path, [phase("scroll", 0, 3)], steady(START, 3, interval=16.7, budget=16.7))
    metrics = perf_tour.load_run(tmp_path)["surfaces"]["scroll"]
    assert metrics["missed_pct"] == 0
    assert metrics["hz"] == pytest.approx(60, abs=0.2)


def test_severe_and_long_frames_are_counted_against_absolute_thresholds(tmp_path):
    frames = steady(START, 1) + [(START + 1.1, 40, BUDGET), (START + 1.5, 150, BUDGET)]
    write_run(tmp_path, [phase("open", 0, 2)], frames)
    metrics = perf_tour.load_run(tmp_path)["surfaces"]["open"]
    assert (metrics["over_33"], metrics["over_100"], metrics["worst_ms"]) == (2, 1, 150)


def test_frames_are_attributed_to_the_phase_window_only(tmp_path):
    frames = steady(START, 1) + [(START + 1.5, 200, BUDGET)] + steady(START + 2, 1)
    write_run(tmp_path, [phase("before", 0, 1), phase("after", 2, 3)], frames)
    surfaces = perf_tour.load_run(tmp_path)["surfaces"]
    assert surfaces["before"]["worst_ms"] < 10
    assert surfaces["after"]["worst_ms"] < 10


def test_cpu_percent_comes_from_the_cumulative_cpu_time_over_the_window(tmp_path):
    cpu = [(START + second, second * 0.5) for second in range(6)]
    write_run(tmp_path, [phase("busy", 1, 4)], steady(START, 5), cpu=cpu)
    assert perf_tour.load_run(tmp_path)["surfaces"]["busy"]["cpu_pct"] == pytest.approx(50)


def test_runs_aggregate_to_the_median_with_their_range(tmp_path):
    for index, hitch_interval in enumerate((20, 40, 60), start=1):
        frames = steady(START, 1) + [(START + 1.1, hitch_interval, BUDGET)] + steady(START + 1.2, 1)
        write_run(tmp_path / f"run-{index}", [phase("scroll", 0, 3)], frames)
    summary = perf_tour.aggregate(tmp_path)
    assert summary["runs"] == 3
    worst = summary["surfaces"]["scroll"]["worst_ms"]
    assert (worst["min"], worst["median"], worst["max"]) == (20, 40, 60)
    assert "(20-60)" in perf_tour.render_summary(summary)


def test_skipped_surfaces_are_listed_with_their_reason(tmp_path):
    write_run(tmp_path, [phase("idle", 0, 1), phase("rooms", 1, 1, skipped="no room driver")], steady(START, 1.5))
    text = perf_tour.render(tmp_path)
    assert "rooms: no room driver" in text
    assert "display link 120 Hz" in text
    assert (tmp_path / "tour-summary.json").is_file()


def test_the_report_warns_when_the_display_never_reached_promotion(tmp_path):
    write_run(tmp_path, [phase("idle", 0, 2)], steady(START, 2, interval=16.7, budget=16.7))
    assert "below ProMotion" in perf_tour.render(tmp_path)


def test_compare_prints_before_and_after_per_surface_and_writes_the_deltas(tmp_path):
    before, after = tmp_path / "before", tmp_path / "after"
    write_run(before / "run-1", [phase("scroll", 0, 3)], steady(START, 1) + [(START + 1.1, 40, BUDGET)] + steady(START + 1.2, 1))
    write_run(after / "run-1", [phase("scroll", 0, 3)], steady(START, 2))
    text = perf_tour.render(before, after)
    assert "scroll" in text
    assert "40 -> 8" in text
    deltas = json.loads((after / "tour-compare.json").read_text())["deltas"]
    assert deltas["scroll"]["worst_ms"] < 0


def test_the_cli_prints_the_table_and_exits_2_on_a_broken_run(tmp_path):
    write_run(tmp_path / "good", [phase("idle", 0, 2)], steady(START, 3))
    ok = subprocess.run([sys.executable, str(PERF_DIR / "perf.py"), "tour", str(tmp_path / "good")], capture_output=True, text=True, check=False, timeout=60)
    assert ok.returncode == 0
    assert "idle" in ok.stdout
    write_run(tmp_path / "bad", [phase("idle", 5, 6)], steady(START, 1))
    bad = subprocess.run([sys.executable, str(PERF_DIR / "perf.py"), "tour", str(tmp_path / "bad")], capture_output=True, text=True, check=False, timeout=60)
    assert bad.returncode == 2
    assert "zero frames" in bad.stderr
