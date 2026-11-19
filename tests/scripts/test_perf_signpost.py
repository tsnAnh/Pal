"""apps/ios/Tools/perf/perf_signpost.py: xctrace signpost exports to the Connect Apps interval report."""

import importlib.util
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


perf_signpost = _load("perf_signpost")
perf_mac_scenario = _load("perf_mac_scenario")

SECOND = 1_000_000_000
MS = 1_000_000


def table(schema, columns, rows):
    header = "".join(f"<col><mnemonic>{name}</mnemonic><name>{name}</name></col>" for name in columns)
    body = ""
    for row in rows:
        body += "<row>" + "".join(cell for cell in row) + "</row>"
    return f'<?xml version="1.0"?><trace-query-result><node xpath="/trace-toc"><schema name="{schema}">{header}</schema>{body}</node></trace-query-result>'


def interval_row(name, start_s, duration_ms, subsystem="app.pal", category="perf"):
    return [
        f'<start-time fmt="x">{int(start_s * SECOND)}</start-time>',
        f'<duration fmt="x">{int(duration_ms * MS)}</duration>',
        f'<subsystem fmt="{subsystem}">{subsystem}</subsystem>',
        f'<category fmt="{category}">{category}</category>',
        f'<string fmt="{name}">{name}</string>',
    ]


def event_row(name, start_s, message="", kind="Event", subsystem="app.pal"):
    return [
        f'<event-time fmt="x">{int(start_s * SECOND)}</event-time>',
        f'<event-type fmt="{kind}">{kind}</event-type>',
        f'<subsystem fmt="{subsystem}">{subsystem}</subsystem>',
        '<category fmt="perf">perf</category>',
        f'<string fmt="{name}">{name}</string>',
        f'<string fmt="{message}">{message}</string>',
    ]


INTERVAL_COLUMNS = ("start", "duration", "subsystem", "category", "name")
EVENT_COLUMNS = ("time", "event-type", "subsystem", "category", "name", "message")


def interval_table(rows):
    return table("os-signpost-interval", INTERVAL_COLUMNS, rows)


def event_table(rows):
    return table("os-signpost", EVENT_COLUMNS, rows)


@pytest.fixture
def exports(tmp_path):
    intervals = tmp_path / "intervals.xml"
    events = tmp_path / "events.xml"
    intervals.write_text(interval_table([
        interval_row("connect.sections.main", 10.0, 2.0),
        interval_row("connect.sections.main", 116.0, 4.0),
        interval_row("connect.sections.main", 117.0, 8.0),
        interval_row("connect.sections.main", 118.0, 6.0),
        interval_row("connect.open", 116.0, 300.0),
        interval_row("connect.localReports", 116.0, 120.0),
        interval_row("roster.apply", 116.0, 3.0),
        interval_row("connect.open", 116.0, 999.0, subsystem="com.apple.other"),
    ]))
    events.write_text(event_table([
        event_row("connect.permission.probe", 116.1, "calendar 2500"),
        event_row("connect.permission.probe", 116.2, "messages 90000"),
        event_row("connect.permission.probe", 116.3, "calendar 1500"),
        event_row("connect.permission.probe", 20.0, "screen 1000"),
        event_row("connect.start.burst", 116.4, "9"),
        event_row("connect.body.main", 116.5),
        event_row("connect.body.main", 117.5),
        event_row("connect.body.main", 5.0),
        event_row("connect.body.main", 116.5, kind="Begin"),
    ]))
    return [intervals, events]


def test_connect_apps_step_window_follows_the_scripted_steps():
    assert perf_mac_scenario.step_window("Connect Apps") == (115, 130)
    assert perf_signpost.window_ms() == (115_000, 130_000)
    assert perf_signpost.window_ms(offset_seconds=2.5) == (117_500, 132_500)


def test_unknown_step_is_an_error():
    with pytest.raises(KeyError):
        perf_mac_scenario.step_window("Nope")


def test_percentiles_are_nearest_rank():
    stats = perf_signpost.summarize([4.0, 1.0, 3.0, 2.0])
    assert stats == {"n": 4, "p50": 2.0, "p95": 4.0, "max": 4.0, "total": 10.0}
    assert perf_signpost.summarize([]) == {"n": 0, "p50": None, "p95": None, "max": None, "total": 0.0}


def test_whole_run_and_step_window_stats_per_interval(exports):
    intervals, events = perf_signpost.load(exports)
    whole = perf_signpost.collect(intervals, events)["intervals"]["connect.sections.main"]
    step = perf_signpost.collect(intervals, events, perf_signpost.window_ms())["intervals"]["connect.sections.main"]
    assert whole == {"n": 4, "p50": 4.0, "p95": 8.0, "max": 8.0, "total": 20.0}
    assert step == {"n": 3, "p50": 6.0, "p95": 8.0, "max": 8.0, "total": 18.0}


def test_only_the_app_pal_perf_signposts_count(exports):
    intervals, events = perf_signpost.load(exports)
    assert perf_signpost.collect(intervals, events)["intervals"]["connect.open"]["n"] == 1
    assert "roster.apply" not in perf_signpost.collect(intervals, events)["intervals"]


def test_permission_probe_events_group_per_connector_slowest_first(exports):
    intervals, events = perf_signpost.load(exports)
    step = perf_signpost.collect(intervals, events, perf_signpost.window_ms())
    assert list(step["probes"]) == ["messages", "calendar"]
    assert step["probes"]["calendar"] == {"n": 2, "p50": 1.5, "p95": 2.5, "max": 2.5, "total": 4.0}
    assert step["probe"]["n"] == 3
    assert perf_signpost.collect(intervals, events)["probe"]["n"] == 4


def test_burst_counts_and_body_evaluations_are_counted_by_window(exports):
    intervals, events = perf_signpost.load(exports)
    whole = perf_signpost.collect(intervals, events)
    step = perf_signpost.collect(intervals, events, perf_signpost.window_ms())
    assert whole["bursts"] == [9] and step["bursts"] == [9]
    assert whole["bodies"] == 3
    assert step["bodies"] == 2


def test_report_lists_every_connect_signpost_even_without_samples(exports):
    text = perf_signpost.render(exports)
    for name in (*perf_signpost.CONNECT_INTERVALS, "connect.permission.probe", "connect.start.burst", "connect.body.main"):
        assert name in text
    assert "step 'Connect Apps' window: 115-130 s" in text
    assert "p50 ms" in text and "p95 ms" in text and "max ms" in text and "total ms" in text
    sections = next(line for line in text.splitlines() if line.strip().startswith("connect.sections.main"))
    assert sections.split() == ["connect.sections.main", "4", "4.00", "8.00", "8.00", "20.00"]
    catalog = next(line for line in text.splitlines() if line.strip().startswith("connect.catalog.build"))
    assert catalog.split() == ["connect.catalog.build", "0", "-", "-", "-", "0.00"]


def test_repeated_values_are_resolved_through_xctrace_refs(tmp_path):
    path = tmp_path / "intervals.xml"
    first = interval_row("connect.sections.main", 116.0, 4.0)
    first[2] = '<subsystem id="7" fmt="app.pal">app.pal</subsystem>'
    second = interval_row("connect.sections.main", 117.0, 6.0)
    second[2] = '<subsystem ref="7"/>'
    path.write_text(interval_table([first, second]))
    intervals, _ = perf_signpost.load([path])
    assert [sample[2] for sample in intervals] == [4.0, 6.0]


def test_unreadable_or_foreign_exports_name_the_problem(tmp_path):
    with pytest.raises(perf_signpost.SignpostError, match="cannot read"):
        perf_signpost.load([tmp_path / "missing.xml"])
    broken = tmp_path / "broken.xml"
    broken.write_text("not xml")
    with pytest.raises(perf_signpost.SignpostError, match="not an xctrace export"):
        perf_signpost.load([broken])
    other = tmp_path / "other.xml"
    other.write_text(table("time-profile", ("time",), []))
    with pytest.raises(perf_signpost.SignpostError, match="unsupported table"):
        perf_signpost.load([other])
    nameless = tmp_path / "nameless.xml"
    nameless.write_text(table("os-signpost-interval", ("start", "duration"), [['<start-time>1</start-time>', '<duration>2</duration>']]))
    with pytest.raises(perf_signpost.SignpostError, match="no subsystem column"):
        perf_signpost.load([nameless])
