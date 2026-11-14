import itertools
import json
import statistics
import sys


def load(path):
    dumps, events = [], []
    for line in open(path):
        record = json.loads(line)
        (dumps if "step" in record else events).append(record)
    return dumps, events


def markers(dump):
    return [row["marker"] for row in dump["rows"] if row["marker"] is not None]


def by_marker(dump):
    return {row["marker"]: row for row in dump["rows"] if row["marker"] is not None}


def median_shift(before, after):
    common = sorted(set(before) & set(after))
    if not common:
        return None, 0
    return statistics.median(after[m]["y"] - before[m]["y"] for m in common), len(common)


def expected_gaps(dump, visible):
    found = []
    seq = markers(dump)
    for a, b in itertools.pairwise(seq):
        if b > a:
            missing = [m for m in range(a + 1, b) if m in visible]
            if missing:
                found.append({"after": a, "before": b, "missing": missing})
    return found


def order_problems(dump):
    problems = []
    previous = None
    for row in dump["rows"]:
        if row["marker"] is None:
            continue
        if previous and (row["marker"] <= previous["marker"] or row["y"] < previous["y"]):
            problems.append({"marker": row["marker"], "after": previous["marker"], "y": row["y"], "previous_y": previous["y"]})
        previous = row
    return problems


def analyze(path, manifest_path):
    rows = json.load(open(manifest_path))["rows"]
    expect = {row["index"]: row["expect"] for row in rows}
    visible = {i for i, kind in expect.items() if kind == "visible"}
    dumps, events = load(path)
    swipe_times = sorted(e["t"] for e in events if e.get("event") in ("swipe", "wiggle"))
    report = {"dumps": len(dumps), "events": len(events), "expected_visible_total": len(visible)}

    seen = {}
    for dump in dumps:
        for row in dump["rows"]:
            if row["marker"] is not None:
                seen.setdefault(row["marker"], dump["t"])
    report["distinct_markers_seen"] = len(seen)
    report["visible_seen"] = len([m for m in seen if m in visible])
    low, high = (min(seen), max(seen)) if seen else (0, 0)
    report["marker_range_seen"] = [low, high]
    report["expected_visible_in_range_never_seen"] = [m for m in sorted(visible) if low <= m <= high and m not in seen]
    report["expected_visible_below_lowest_seen"] = len([m for m in visible if m < low])
    report["leaked_hidden_or_tool"] = sorted(m for m in seen if expect.get(m) in ("hidden", "tool"))
    report["notice_rows_seen"] = sorted(m for m in seen if expect.get(m) == "notice")
    report["unknown_markers"] = sorted(m for m in seen if m not in expect)
    report["rows_without_marker"] = sum(1 for d in dumps for r in d["rows"] if r["marker"] is None) and len({
        (r["id"], r["len"]) for d in dumps for r in d["rows"] if r["marker"] is None})

    gap_events = {}
    duplicate_dumps, order_dumps = [], []
    for dump in dumps:
        for gap in expected_gaps(dump, visible):
            key = (gap["after"], gap["before"])
            entry = gap_events.setdefault(key, {**gap, "first_t": dump["t"], "step": dump["step"], "dumps": 0})
            entry["dumps"] += 1
        seq = markers(dump)
        if len(seq) != len(set(seq)):
            duplicate_dumps.append({"t": dump["t"], "step": dump["step"], "duplicates": sorted({m for m in seq if seq.count(m) > 1})})
        problems = order_problems(dump)
        if problems:
            order_dumps.append({"t": dump["t"], "step": dump["step"], "problems": problems[:5]})
    report["gaps_in_tree_order"] = sorted(gap_events.values(), key=lambda g: g["first_t"])
    report["duplicate_marker_dumps"] = duplicate_dumps[:20]
    report["order_violation_dumps"] = order_dumps[:20]

    shifts, growths = [], []
    for earlier, later in itertools.pairwise(dumps):
        swiped = any(earlier["t"] < t < later["t"] for t in swipe_times)
        a, b = by_marker(earlier), by_marker(later)
        shift, common = median_shift(a, b)
        added = sorted(set(b) - set(a))
        removed = sorted(set(a) - set(b))
        entry = {
            "t": later["t"], "step": later["step"], "swipe_between": swiped, "common": common,
            "median_shift": shift, "added": len(added), "removed": len(removed),
            "added_range": [added[0], added[-1]] if added else None, "removed_range": [removed[0], removed[-1]] if removed else None,
            "rows_before": len(a), "rows_after": len(b),
        }
        if added or removed:
            growths.append(entry)
        if not swiped and shift is not None and abs(shift) > 1.5:
            shifts.append(entry)
    swipe_shifts = []
    for earlier, later in itertools.pairwise(dumps):
        if any(earlier["t"] < t < later["t"] for t in swipe_times):
            shift, common = median_shift(by_marker(earlier), by_marker(later))
            if shift is not None:
                swipe_shifts.append({"t": later["t"], "shift": shift, "common": common, "added": len(set(by_marker(later)) - set(by_marker(earlier)))})
    plain = [s["shift"] for s in swipe_shifts if s["added"] == 0 and s["common"] >= 3]
    baseline = statistics.median(plain) if plain else None
    report["swipe_displacement_baseline_pt"] = baseline
    report["swipes_total"] = len(swipe_shifts)
    if baseline is not None:
        report["swipe_jumps_vs_baseline"] = [
            {"t": round(s["t"], 1), "excess_pt": round(s["shift"] - baseline, 1), "added": s["added"], "common": s["common"]}
            for s in swipe_shifts if abs(s["shift"] - baseline) > 8]
    report["unprompted_shifts_while_idle"] = [
        {**s, "median_shift": round(s["median_shift"], 1)} for s in shifts]
    report["row_set_changes"] = growths[:400]

    latencies = []
    for index, swipe_t in enumerate(swipe_times):
        following = [d for d in dumps if d["t"] > swipe_t]
        if len(following) < 2:
            continue
        first = by_marker(following[0])
        for later in following[1:]:
            if later["step"] != following[0]["step"] and later["step"] != following[1]["step"]:
                break
            if len(by_marker(later)) > len(first) or (markers(later) and markers(following[0]) and min(markers(later)) < min(markers(following[0]))):
                latencies.append({"swipe": index, "grew_after_s": round(later["t"] - swipe_t, 2),
                                  "added": len(set(by_marker(later)) - set(first))})
                break
    report["load_latency_after_swipe"] = latencies
    report["snapshot_seconds_median"] = statistics.median(d["snapshotSeconds"] for d in dumps) if dumps else None
    report["status_seen"] = sorted({k for d in dumps for k in d["status"]})
    reconnect = [d for d in dumps if d["status"].get("reconnectingIndicator")]
    report["reconnecting_indicator_samples"] = len(reconnect)
    return report


if __name__ == "__main__":
    print(json.dumps(analyze(sys.argv[1], sys.argv[2]), indent=1))
