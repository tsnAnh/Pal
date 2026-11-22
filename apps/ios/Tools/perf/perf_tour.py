import csv
import json
import math
import statistics
from bisect import bisect_left, bisect_right
from pathlib import Path

FRAMES_FILE = "pal-frames.csv"
PHASES_FILE = "phases.jsonl"
CPU_FILE = "cpu.csv"
SUMMARY_FILE = "tour-summary.json"
COMPARE_FILE = "tour-compare.json"
HITCH_FACTOR = 1.5
SEVERE_MS = 33.0
LONG_MS = 100.0
LOW_REFRESH_HZ = 110
METRICS = ("frames", "hz", "p50_ms", "p95_ms", "p99_ms", "missed_pct", "hitch_ms_per_s", "worst_ms", "over_33", "over_100", "cpu_pct")
RANGED = ("p95_ms", "missed_pct", "hitch_ms_per_s", "worst_ms")


class TourError(ValueError):
    pass


def percentile(sorted_values, fraction):
    if not sorted_values:
        raise TourError("no values to take a percentile of")
    position = (len(sorted_values) - 1) * fraction
    low, high = math.floor(position), math.ceil(position)
    return sorted_values[low] + (sorted_values[high] - sorted_values[low]) * (position - low)


def perf_directory(run_dir):
    run_dir = Path(run_dir)
    return run_dir / "perf" if (run_dir / "perf").is_dir() else run_dir


def read_phases(path):
    if not path.is_file():
        raise TourError(f"no {PHASES_FILE} in {path.parent}; the tour test did not write its phases")
    phases = []
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        try:
            row = json.loads(line)
            phase = {"surface": row["surface"], "start": float(row["startedAt"]), "end": float(row["endedAt"]), "skipped": row.get("skipped")}
        except (ValueError, KeyError, TypeError) as error:
            raise TourError(f"{path}:{number}: bad phase line ({error})") from None
        if phase["end"] < phase["start"]:
            raise TourError(f"{path}:{number}: phase {phase['surface']} ends before it starts")
        phases.append(phase)
    if not phases:
        raise TourError(f"{path} is empty: the tour recorded no phases")
    return phases


def read_frames(path):
    if not path.is_file():
        raise TourError(f"no {FRAMES_FILE} in {path.parent}; the app never wrote its frame log (PAL_PERF off, or it was killed before its first flush)")
    epochs, intervals, budgets = [], [], []
    with path.open(newline="", encoding="utf-8") as handle:
        reader = csv.reader(handle)
        header = next(reader, None)
        if header != ["epoch_s", "interval_ms", "budget_ms"]:
            raise TourError(f"{path}: unexpected header {header}")
        for row in reader:
            if len(row) != 3:
                continue
            epochs.append(float(row[0]))
            intervals.append(float(row[1]))
            budgets.append(float(row[2]))
    if not epochs:
        raise TourError(f"{path} holds no frames")
    order = sorted(range(len(epochs)), key=epochs.__getitem__)
    return [epochs[i] for i in order], [intervals[i] for i in order], [budgets[i] for i in order]


def parse_cpu_time(text):
    seconds = 0.0
    for part in text.split(":"):
        seconds = seconds * 60 + float(part)
    return seconds


def read_cpu(path):
    if not path.is_file():
        return []
    samples = []
    with path.open(newline="", encoding="utf-8") as handle:
        for row in csv.DictReader(handle):
            samples.append((float(row["epoch_s"]), float(row["cpu_s"])))
    return sorted(samples)


def cpu_at(samples, moment):
    times = [sample[0] for sample in samples]
    index = bisect_left(times, moment)
    if index == 0 or index == len(samples):
        return None
    (t0, c0), (t1, c1) = samples[index - 1], samples[index]
    return c0 + (c1 - c0) * (moment - t0) / (t1 - t0) if t1 > t0 else c0


def cpu_percent(samples, start, end):
    if len(samples) < 2 or end <= start:
        return None
    begin, finish = cpu_at(samples, start), cpu_at(samples, end)
    if begin is None or finish is None:
        return None
    return max(finish - begin, 0.0) / (end - start) * 100


def phase_metrics(phase, frames, cpu):
    epochs, intervals, budgets = frames
    low, high = bisect_left(epochs, phase["start"]), bisect_right(epochs, phase["end"])
    window = intervals[low:high]
    if not window:
        raise TourError(f"phase {phase['surface']} has zero frames: the frame log has none between its start and end, so the measurement did not happen")
    budget_window = budgets[low:high]
    ordered = sorted(window)
    duration = max(phase["end"] - phase["start"], 1e-9)
    missed = [(interval, budget) for interval, budget in zip(window, budget_window) if interval > budget * HITCH_FACTOR]
    metrics = {
        "frames": len(window),
        "hz": 1000 / statistics.median(budget_window),
        "p50_ms": percentile(ordered, 0.50),
        "p95_ms": percentile(ordered, 0.95),
        "p99_ms": percentile(ordered, 0.99),
        "missed_pct": len(missed) / len(window) * 100,
        "hitch_ms_per_s": sum(interval - budget for interval, budget in missed) / duration,
        "worst_ms": ordered[-1],
        "over_33": sum(1 for value in window if value > SEVERE_MS),
        "over_100": sum(1 for value in window if value > LONG_MS),
        "cpu_pct": cpu_percent(cpu, phase["start"], phase["end"]),
        "duration_s": duration,
    }
    return metrics


def load_run(run_dir):
    directory = perf_directory(run_dir)
    phases = read_phases(directory / PHASES_FILE)
    frames = read_frames(directory / FRAMES_FILE)
    cpu = read_cpu(Path(run_dir) / CPU_FILE)
    surfaces, skipped = {}, {}
    for phase in phases:
        if phase["skipped"]:
            skipped[phase["surface"]] = phase["skipped"]
        else:
            surfaces[phase["surface"]] = phase_metrics(phase, frames, cpu)
    if not surfaces:
        raise TourError(f"every phase in {directory / PHASES_FILE} was skipped: {sorted(skipped.items())}")
    return {"dir": str(run_dir), "surfaces": surfaces, "skipped": skipped, "order": [phase["surface"] for phase in phases]}


def run_directories(path):
    path = Path(path)
    runs = sorted(path.glob("run-*"), key=lambda item: int(item.name.split("-", 1)[1]) if item.name.split("-", 1)[1].isdigit() else 0)
    runs = [run for run in runs if run.is_dir()]
    return runs or [path]


def aggregate(path):
    runs = [load_run(run) for run in run_directories(path)]
    order = []
    for run in runs:
        order += [surface for surface in run["order"] if surface not in order]
    surfaces, skipped = {}, {}
    for surface in order:
        measured = [run["surfaces"][surface] for run in runs if surface in run["surfaces"]]
        if not measured:
            skipped[surface] = min(run["skipped"][surface] for run in runs if surface in run["skipped"])
            continue
        cell = {}
        for metric in METRICS:
            values = [item[metric] for item in measured if item[metric] is not None]
            cell[metric] = {"median": statistics.median(values), "min": min(values), "max": max(values)} if values else None
        cell["runs"] = len(measured)
        cell["duration_s"] = statistics.median(item["duration_s"] for item in measured)
        surfaces[surface] = cell
    return {"runs": len(runs), "run_dirs": [run["dir"] for run in runs], "surfaces": surfaces, "skipped": skipped}


FORMATS = {"frames": "{:.0f}", "hz": "{:.0f}", "p50_ms": "{:.1f}", "p95_ms": "{:.1f}", "p99_ms": "{:.1f}", "missed_pct": "{:.1f}",
           "hitch_ms_per_s": "{:.1f}", "worst_ms": "{:.0f}", "over_33": "{:.0f}", "over_100": "{:.0f}", "cpu_pct": "{:.0f}"}
HEADERS = {"frames": "frames", "hz": "Hz", "p50_ms": "p50", "p95_ms": "p95", "p99_ms": "p99", "missed_pct": "miss%", "hitch_ms_per_s": "hitch ms/s",
           "worst_ms": "worst", "over_33": ">33", "over_100": ">100", "cpu_pct": "cpu%"}


def cell_text(cell, metric, ranged):
    stats = cell[metric]
    if stats is None:
        return "-"
    text = FORMATS[metric].format(stats["median"])
    if ranged and metric in RANGED and cell["runs"] > 1:
        text += f" ({FORMATS[metric].format(stats['min'])}-{FORMATS[metric].format(stats['max'])})"
    return text


def table(rows, headers):
    widths = [max(len(str(row[index])) for row in [headers, *rows]) for index in range(len(headers))]
    lines = ["  ".join(str(value).ljust(widths[0]) if index == 0 else str(value).rjust(widths[index]) for index, value in enumerate(row)) for row in [headers, *rows]]
    lines.insert(1, "  ".join("-" * width for width in widths))
    return "\n".join(lines)


def display_line(summary):
    budgets = [1000 / cell["hz"]["median"] for cell in summary["surfaces"].values()]
    hz = statistics.median(1000 / budget for budget in budgets)
    note = "" if hz >= LOW_REFRESH_HZ else "  WARNING: below ProMotion, so the 120 Hz numbers below are not 120 Hz numbers"
    return f"display link {hz:.0f} Hz (budget {1000 / hz:.2f} ms), missed = frame interval > {HITCH_FACTOR:g} x budget{note}"


def render_summary(summary):
    metrics = list(METRICS)
    headers = ["surface", *(HEADERS[metric] for metric in metrics)]
    rows = [[surface, *(cell_text(cell, metric, True) for metric in metrics)] for surface, cell in summary["surfaces"].items()]
    lines = [f"{summary['runs']} run(s): median across runs, range in brackets for p95, miss%, hitch ms/s and worst", display_line(summary), "", table(rows, headers)]
    if summary["skipped"]:
        lines += ["", "skipped surfaces:"] + [f"  {surface}: {reason}" for surface, reason in summary["skipped"].items()]
    return "\n".join(lines) + "\n"


def delta_text(before, after, metric):
    if before is None or after is None:
        return "-"
    fmt = FORMATS[metric]
    change = after["median"] - before["median"]
    return f"{fmt.format(before['median'])} -> {fmt.format(after['median'])} ({'+' if change >= 0 else '-'}{fmt.format(abs(change))})"


def compare(before, after):
    shared = [surface for surface in before["surfaces"] if surface in after["surfaces"]]
    compared = ("p95_ms", "missed_pct", "hitch_ms_per_s", "worst_ms", "cpu_pct")
    rows = [[surface, *(delta_text(before["surfaces"][surface][metric], after["surfaces"][surface][metric], metric) for metric in compared)] for surface in shared]
    only = {"only before": [s for s in before["surfaces"] if s not in after["surfaces"]], "only after": [s for s in after["surfaces"] if s not in before["surfaces"]]}
    lines = [f"before {before['runs']} run(s) vs after {after['runs']} run(s), medians; negative deltas are better except cpu% neutral", display_line(after), "",
             table(rows, ["surface", *(HEADERS[metric] for metric in compared)])]
    for label, names in only.items():
        if names:
            lines += ["", f"{label}: {', '.join(names)}"]
    deltas = {surface: {metric: None if None in (before["surfaces"][surface][metric], after["surfaces"][surface][metric])
                        else after["surfaces"][surface][metric]["median"] - before["surfaces"][surface][metric]["median"] for metric in compared} for surface in shared}
    return "\n".join(lines) + "\n", deltas


def render(directory, after_directory=None):
    before = aggregate(directory)
    Path(directory, SUMMARY_FILE).write_text(json.dumps(before, indent=1))
    if after_directory is None:
        return render_summary(before)
    after = aggregate(after_directory)
    Path(after_directory, SUMMARY_FILE).write_text(json.dumps(after, indent=1))
    text, deltas = compare(before, after)
    Path(after_directory, COMPARE_FILE).write_text(json.dumps({"before": str(directory), "after": str(after_directory), "deltas": deltas}, indent=1))
    return render_summary(after) + "\n" + text
