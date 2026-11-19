import math
import xml.etree.ElementTree as ET
from collections import defaultdict
from pathlib import Path

import perf_mac_scenario

SUBSYSTEM = "app.pal"
CATEGORY = "perf"
STEP_TITLE = "Connect Apps"
INTERVAL_SCHEMA = "os-signpost-interval"
EVENT_SCHEMA = "os-signpost"
CONNECT_INTERVALS = (
    "connect.open", "connect.catalog.build", "connect.sections.main", "connect.localReports", "connect.messagesdb.probe",
)
PROBE_EVENT = "connect.permission.probe"
BURST_EVENT = "connect.start.burst"
BODY_EVENT = "connect.body.main"
NANOSECONDS_PER_MILLISECOND = 1_000_000
MICROSECONDS_PER_MILLISECOND = 1000


class SignpostError(ValueError):
    pass


def percentile(ordered, fraction):
    return ordered[max(math.ceil(fraction * len(ordered)), 1) - 1]


def summarize(values):
    ordered = sorted(values)
    if not ordered:
        return {"n": 0, "p50": None, "p95": None, "max": None, "total": 0.0}
    return {"n": len(ordered), "p50": percentile(ordered, 0.5), "p95": percentile(ordered, 0.95), "max": ordered[-1], "total": sum(ordered)}


def cell_value(cell):
    return cell.text.strip() if cell.text and cell.text.strip() else cell.get("fmt", "")


def parse_table(text):
    try:
        root = ET.fromstring(text)
    except ET.ParseError as error:
        raise SignpostError(f"not an xctrace export: {error}") from None
    schema = root.find(".//schema")
    if schema is None:
        raise SignpostError("export holds no table schema")
    mnemonics = [column.findtext("mnemonic") for column in schema.findall("col")]
    seen = {}
    rows = []
    for row in root.iter("row"):
        values = {}
        for mnemonic, cell in zip(mnemonics, list(row)):
            if (reference := cell.get("ref")) is not None:
                value = seen.get(reference, "")
            else:
                value = cell_value(cell)
                if cell.get("id") is not None:
                    seen[cell.get("id")] = value
            values[mnemonic] = value
        rows.append(values)
    return schema.get("name"), mnemonics, rows


def field(row, mnemonics, *candidates):
    for name in candidates:
        if name in row:
            return row[name]
    raise SignpostError(f"table has no {'/'.join(candidates)} column; columns are {', '.join(map(str, mnemonics))}")


def is_pal_perf(row, mnemonics):
    return field(row, mnemonics, "subsystem") == SUBSYSTEM and field(row, mnemonics, "category") == CATEGORY


def number(value, what):
    try:
        return float(value)
    except ValueError:
        raise SignpostError(f"{what} is not a number: {value!r}") from None


def interval_samples(mnemonics, rows):
    samples = []
    for row in rows:
        if is_pal_perf(row, mnemonics):
            start = number(field(row, mnemonics, "start", "start-time"), "interval start")
            duration = number(field(row, mnemonics, "duration"), "interval duration")
            samples.append((field(row, mnemonics, "name"), start / NANOSECONDS_PER_MILLISECOND, duration / NANOSECONDS_PER_MILLISECOND))
    return samples


def event_samples(mnemonics, rows):
    samples = []
    for row in rows:
        if is_pal_perf(row, mnemonics) and row.get("event-type", "Event") == "Event":
            time = number(field(row, mnemonics, "time", "start"), "event time")
            samples.append((field(row, mnemonics, "name"), time / NANOSECONDS_PER_MILLISECOND, row.get("message", "")))
    return samples


def load(paths):
    intervals, events = [], []
    for path in paths:
        try:
            text = Path(path).read_text(encoding="utf-8")
        except OSError as error:
            raise SignpostError(f"cannot read {path}: {error.strerror or error}") from None
        schema, mnemonics, rows = parse_table(text)
        if schema == INTERVAL_SCHEMA:
            intervals += interval_samples(mnemonics, rows)
        elif schema == EVENT_SCHEMA:
            events += event_samples(mnemonics, rows)
        else:
            raise SignpostError(f"{path}: unsupported table {schema!r}; export {INTERVAL_SCHEMA} and {EVENT_SCHEMA}")
    return intervals, events


def window_ms(offset_seconds=0.0, title=STEP_TITLE):
    start, end = perf_mac_scenario.step_window(title)
    return (start + offset_seconds) * 1000, (end + offset_seconds) * 1000


def within(samples, window):
    return [sample for sample in samples if window is None or window[0] <= sample[1] < window[1]]


def probe_parts(message):
    label, _, microseconds = message.rpartition(" ")
    try:
        return label, int(microseconds) / MICROSECONDS_PER_MILLISECOND
    except ValueError:
        return None


def burst_count(message):
    try:
        return int(message.strip())
    except ValueError:
        return None


def collect(intervals, events, window=None):
    intervals, events = within(intervals, window), within(events, window)
    by_name = defaultdict(list)
    for name, _, duration in intervals:
        by_name[name].append(duration)
    probes = defaultdict(list)
    bursts = []
    bodies = 0
    for name, _, message in events:
        if name == PROBE_EVENT and (parts := probe_parts(message)):
            probes[parts[0]].append(parts[1])
        elif name == BURST_EVENT and (count := burst_count(message)) is not None:
            bursts.append(count)
        elif name == BODY_EVENT:
            bodies += 1
    return {
        "intervals": {name: summarize(by_name.get(name, [])) for name in CONNECT_INTERVALS},
        "probe": summarize([value for values in probes.values() for value in values]),
        "probes": {label: summarize(values) for label, values in sorted(probes.items(), key=lambda item: -sum(item[1]))},
        "bursts": bursts,
        "bodies": bodies,
    }


def cell(value, digits=2):
    return "-" if value is None else f"{value:.{digits}f}"


def row_line(name, stats):
    return f"  {name:<28} {stats['n']:>5} {cell(stats['p50']):>9} {cell(stats['p95']):>9} {cell(stats['max']):>9} {cell(stats['total']):>10}"


def scope_lines(title, collected):
    lines = [title, f"  {'signpost':<28} {'n':>5} {'p50 ms':>9} {'p95 ms':>9} {'max ms':>9} {'total ms':>10}"]
    lines += [row_line(name, stats) for name, stats in collected["intervals"].items()]
    lines.append(row_line(PROBE_EVENT, collected["probe"]))
    lines += [row_line(f"  {label}", stats) for label, stats in collected["probes"].items()]
    bursts = collected["bursts"]
    lines.append(f"  {BURST_EVENT:<28} {len(bursts):>5}  rpc counts per open: {', '.join(map(str, bursts)) or '-'}")
    lines.append(f"  {BODY_EVENT:<28} {collected['bodies']:>5}  body evaluations")
    return lines


def render(paths, offset_seconds=0.0, title=STEP_TITLE):
    intervals, events = load(paths)
    start, end = window_ms(offset_seconds, title)
    lines = [
        f"Connect Apps signposts (subsystem {SUBSYSTEM}, category {CATEGORY}); percentiles are nearest-rank",
        f"step '{title}' window: {start / 1000:g}-{end / 1000:g} s after the trace start (step offset {offset_seconds:g} s)",
        "",
        *scope_lines("whole run", collect(intervals, events)),
        "",
        *scope_lines(f"step '{title}'", collect(intervals, events, (start, end))),
    ]
    return "\n".join(lines) + "\n"
