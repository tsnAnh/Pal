"""apps/ios/Tools/perf/scroll_trace.py: jump detection over a PAL_SCROLL_TRACE CSV."""

import importlib.util
from pathlib import Path

import pytest

PERF_DIR = Path(__file__).resolve().parents[2] / "apps" / "ios" / "Tools" / "perf"


def _load(name):
    spec = importlib.util.spec_from_file_location(name, PERF_DIR / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


scroll_trace = _load("scroll_trace")
HEADER = ",".join(scroll_trace.COLUMNS)


def row(at, kind="geo", reason="", mode="reading", phase="idle", distance=300.0, pin="7", pin_min_y=500.0, content_h=4000.0):
    fields = [f"{at:.3f}", kind, reason, mode, phase, "", "60", "0", f"{content_h}", "800", f"{distance}", "52", "80", pin, f"{pin_min_y}", "40"]
    return ",".join(fields)


def trace(*rows):
    return "\n".join((HEADER, *rows)) + "\n"


def test_idle_shift_is_a_jump_and_names_the_writes_before_it():
    lines = scroll_trace.parse(trace(
        row(0.000),
        row(0.010, kind="rows"),
        row(0.016, kind="pin", pin_min_y=540.0, content_h=4040.0),
        row(0.032, kind="write", reason="anchor", distance=340.0, pin_min_y=540.0),
    ))
    found = scroll_trace.jumps(lines)
    assert [round(j.moved) for j in found] == [40, -40]
    assert [c.kind for c in found[0].causes] == ["rows"]


def test_user_scroll_is_not_a_jump():
    lines = scroll_trace.parse(trace(row(0.0, phase="interacting"), row(0.016, phase="interacting", distance=200.0)))
    assert scroll_trace.jumps(lines) == []


def test_an_intended_jump_may_animate_without_counting():
    lines = scroll_trace.parse(trace(
        row(0.0),
        row(0.01, kind="write", reason="jump"),
        row(0.2, distance=100.0),
        row(0.6, distance=0.0),
    ))
    assert [round(j.moved) for j in scroll_trace.jumps(lines)] == [100]


def test_a_new_pinned_row_starts_a_new_baseline():
    lines = scroll_trace.parse(trace(row(0.0, pin="7"), row(0.016, kind="pin", pin="9", pin_min_y=900.0)))
    assert scroll_trace.jumps(lines) == []


def test_a_csv_that_is_not_a_scroll_trace_is_refused(tmp_path):
    path = tmp_path / "frames.csv"
    path.write_text("epoch_s,interval_ms,budget_ms\n1.0,16.7,16.7\n")
    assert scroll_trace.main([str(path)]) == 2
    with pytest.raises(scroll_trace.TraceError):
        scroll_trace.parse(path.read_text())


def test_max_jumps_fails_the_run(tmp_path, capsys):
    path = tmp_path / "trace.csv"
    path.write_text(trace(row(0.0), row(0.016, distance=320.0)))
    assert scroll_trace.main([str(path), "--max-jumps", "0"]) == 1
    assert "JUMP t=0.016s moved -20.0pt" in capsys.readouterr().out
