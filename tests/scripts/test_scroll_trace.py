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
HEADER = ",".join(scroll_trace.COLUMNS_V1)
FIXTURES = Path(__file__).parent / "fixtures" / "scroll_trace"


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
    out = capsys.readouterr().out
    assert "jumps=1 viewport=0 anchor=1" in out
    assert "JUMP anchor t=0.016s moved -20.0pt" in out


def test_a_row_appended_at_the_newest_edge_while_following_is_not_a_jump():
    lines = scroll_trace.parse(trace(
        row(0.0, mode="following", distance=0.0, pin_min_y=0.0),
        row(0.010, kind="rows", mode="following", distance=0.0, pin_min_y=0.0),
        row(0.016, kind="pin", mode="following", distance=0.0, pin_min_y=44.0),
    ))
    assert scroll_trace.jumps(lines) == []


def test_following_list_pushed_off_the_newest_edge_is_a_viewport_jump():
    lines = scroll_trace.parse(trace(
        row(0.0, mode="following", distance=0.0, pin_min_y=0.0),
        row(0.010, kind="chrome", mode="following", distance=0.0, pin_min_y=0.0),
        row(0.016, mode="following", distance=88.0, pin_min_y=0.0),
    ))
    found = scroll_trace.jumps(lines)
    assert [(j.kind, round(j.moved)) for j in found] == [("viewport", 88)]
    assert [c.kind for c in found[0].causes] == ["chrome"]


def _run(name, capsys, *extra):
    code = scroll_trace.main([str(FIXTURES / f"{name}.csv"), *extra])
    return code, capsys.readouterr().out


def _kinds(name):
    return [j.kind for j in scroll_trace.jumps(scroll_trace.parse((FIXTURES / f"{name}.csv").read_text()))]


@pytest.mark.parametrize(
    ("name", "kinds"),
    [
        ("v1_a_open_bounce", ["viewport", "viewport"]),
        ("v1_b_composer_hold", ["viewport", "viewport", "viewport"]),
        ("v1_e_layout_oscillation", ["viewport"] * 4),
        ("v1_f_reading_drift", ["anchor", "anchor"]),
        ("v2_pinned_displaced", ["viewport", "viewport"]),
        ("v2_reading_anchor_slip", ["anchor"]),
    ],
)
def test_each_measured_signature_is_flagged_and_fails_the_gate(name, kinds, capsys):
    assert _kinds(name) == kinds
    code, out = _run(name, capsys, "--max-jumps", "0")
    assert code == 1
    assert f"jumps={len(kinds)} " in out and out.count("JUMP ") == len(kinds)


@pytest.mark.parametrize(
    "name",
    [
        "v1_d_artefact_pin_push",
        "v2_clean_pinned_streaming",
        "v2_clean_reading_growth_below",
        "v2_clean_prepend_restore",
        "v2_clean_jump_animation",
    ],
)
def test_clean_runs_pass_the_gate(name, capsys):
    code, out = _run(name, capsys, "--max-jumps", "0")
    assert code == 0
    assert "jumps=0 viewport=0 anchor=0" in out


def test_v2_jump_causes_name_the_machine_event_and_command(capsys):
    _, out = _run("v2_pinned_displaced", capsys)
    assert "machine:rowsChanged->none" in out


def test_v2_jump_without_the_machine_line_is_flagged():
    text = (FIXTURES / "v2_clean_jump_animation.csv").read_text()
    kept = [ln for ln in text.splitlines() if ",machine," not in ln and ",programmatic," not in ln]
    assert [j.kind for j in scroll_trace.jumps(scroll_trace.parse("\n".join(kept) + "\n"))] == ["viewport"]


def test_a_threshold_above_the_move_hides_it(capsys):
    code, _ = _run("v1_f_reading_drift", capsys, "--threshold", "10", "--max-jumps", "0")
    assert code == 0


HEADER_V3 = ",".join(scroll_trace.COLUMNS_V3)


def row_v3(at, distance, button, writer="none", mode="pinnedToBottom", phase="idle", user="0", kind="geo"):
    base = row(at, kind=kind, mode=mode, phase=phase, distance=distance).split(",")
    tail = ["top-down", "400", "", mode if kind == "machine" else "", "", writer, "0.00", "1" if distance <= 1 else "0", button, user]
    return ",".join(base + tail)


def trace_v3(*rows):
    return "\n".join((HEADER_V3, *rows)) + "\n"


def test_v3_button_up_at_the_bottom_is_a_fault_and_fails_the_gate(tmp_path, capsys):
    path = tmp_path / "trace.csv"
    path.write_text(trace_v3(
        row_v3(0.0, 0.0, "0"),
        row_v3(0.1, 12.0, "1", mode="readingHistory"),
        row_v3(0.2, 90.0, "1", mode="readingHistory"),
    ))
    lines = scroll_trace.parse(path.read_text())
    assert [f.distance for f in scroll_trace.button_faults(lines)] == [12.0]
    assert scroll_trace.main([str(path), "--max-button-faults", "0"]) == 1
    assert "button_faults=1 hide_distance=24.0pt" in capsys.readouterr().out


def test_v3_reveal_of_a_row_may_show_the_button_near_the_bottom():
    lines = scroll_trace.parse(trace_v3(row_v3(0.0, 10.0, "1", mode="programmatic")))
    assert scroll_trace.button_faults(lines) == []


def test_v3_writers_are_counted_and_named_on_a_jump(capsys, tmp_path):
    path = tmp_path / "trace.csv"
    path.write_text(trace_v3(
        row_v3(0.0, 0.0, "0"),
        row_v3(0.5, 0.0, "0", writer="machine:scrollToBottom"),
        row_v3(0.9, 50.0, "0", writer="system-anchor"),
    ))
    assert scroll_trace.writers(scroll_trace.parse(path.read_text())) == {"machine:scrollToBottom": 1, "system-anchor": 1}
    scroll_trace.main([str(path)])
    assert "writer=system-anchor" in capsys.readouterr().out


HEADER_V4 = ",".join(scroll_trace.COLUMNS_V4)


def geo_v4(at, writer="none", offset_delta=0.0, content_delta=0.0, source="none", content_h=4000.0, user="0", phase="idle"):
    fields = [
        f"{at:.3f}", "geo", "", "pinnedToBottom", phase, "", "60", "0", f"{content_h}", "800", "0", "", "", "7", "500", "40",
        "top-down", "600", "", "", "", writer, f"{offset_delta}", "1", "0", user, f"{content_delta}", source,
    ]
    return ",".join(fields)


def trace_v4(*rows):
    return "\n".join((HEADER_V4, *rows)) + "\n"


def test_idle_swings_count_only_system_or_unattributed_moves_over_the_threshold():
    lines = scroll_trace.parse(trace_v4(
        geo_v4(0.0),
        geo_v4(0.016, writer="system-anchor", offset_delta=-31.0, content_delta=12.0, source="estimate-replaced"),
        geo_v4(0.032, writer="unattributed", offset_delta=1.5),
        geo_v4(0.048, writer="user", offset_delta=80.0, user="1", phase="interacting"),
        geo_v4(0.064, writer="machine:scrollToBottom", offset_delta=120.0),
        geo_v4(0.080, writer="unattributed", offset_delta=-2.5),
        geo_v4(0.096, writer="system-anchor", offset_delta=300.0, content_delta=300.0, source="streaming-growth"),
    ))
    assert [swing.offset_delta for swing in scroll_trace.idle_swings(lines)] == [-31.0, -2.5]
    assert len(scroll_trace.idle_swings(lines, threshold=50.0)) == 0


def test_streaming_shrinks_and_content_sources_are_reported_and_gate_the_run(tmp_path, capsys):
    path = tmp_path / "trace.csv"
    path.write_text(trace_v4(
        geo_v4(0.0),
        geo_v4(0.016, content_delta=20.0, source="streaming-growth"),
        geo_v4(0.032, content_delta=-14.0, source="streaming-growth"),
        geo_v4(0.048, content_delta=300.0, source="rows"),
    ))
    assert scroll_trace.main([str(path), "--max-streaming-shrinks", "0"]) == 1
    out = capsys.readouterr().out
    assert "streaming_shrinks=1" in out
    assert "content_sources={'streaming-growth': 2, 'rows': 1}" in out
    assert scroll_trace.main([str(path), "--max-streaming-shrinks", "1", "--max-idle-swings", "0"]) == 0


def test_older_traces_still_parse_without_content_columns():
    lines = scroll_trace.parse(trace(row(0.0), row(0.016)))
    assert scroll_trace.idle_swings(lines) == [] and scroll_trace.streaming_shrinks(lines) == []
    assert scroll_trace.content_sources(lines) == {}
