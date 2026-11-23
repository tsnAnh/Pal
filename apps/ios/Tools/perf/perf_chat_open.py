import argparse
import json
import os
import sys
from pathlib import Path

import perf_signpost

TRACE_NAME = "pal-chat-open.jsonl"
DIRECTORY_KEY = "PAL_PERF_DIR"
SLOW_NEWEST_MS = 150
STEPS = (
    "open.tap", "cache.load.begin", "cache.load.end", "cache.frame", "syncing", "connect.begin", "connect.end",
    "resolve.end", "page.adopted", "live", "frame.newest", "session.warm",
)
SYNCING = "syncing"
CACHE_FRAME = "cache.frame"
NEWEST_FRAME = "frame.newest"
OPTIONAL_INTS = ("cachedSeq", "gatewaySeq", "rows")


class ChatOpenError(ValueError):
    pass


def is_int(value):
    return isinstance(value, int) and not isinstance(value, bool)


def is_number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def parse_line(path, number, text):
    where = f"{path}:{number}"
    try:
        record = json.loads(text)
    except json.JSONDecodeError as error:
        raise ChatOpenError(f"{where}: not JSON: {error.msg}") from None
    if not isinstance(record, dict):
        raise ChatOpenError(f"{where}: expected a JSON object")
    if not isinstance(record.get("bot"), str) or not isinstance(record.get("step"), str):
        raise ChatOpenError(f"{where}: bot and step must be strings")
    if not is_number(record.get("ms")):
        raise ChatOpenError(f"{where}: ms must be a number")
    if not is_int(record.get("open")):
        raise ChatOpenError(f"{where}: open must be an integer")
    for key in OPTIONAL_INTS:
        if record.get(key) is not None and not is_int(record[key]):
            raise ChatOpenError(f"{where}: {key} must be an integer or null")
    if record.get("detail") is not None and not isinstance(record["detail"], str):
        raise ChatOpenError(f"{where}: detail must be a string or null")
    return record


def resolve(paths):
    if paths:
        return [Path(path) / TRACE_NAME if Path(path).is_dir() else Path(path) for path in paths]
    directory = os.environ.get(DIRECTORY_KEY)
    if not directory:
        raise ChatOpenError(f"no trace given and {DIRECTORY_KEY} is not set; pass a {TRACE_NAME} path or its directory")
    return [Path(directory) / TRACE_NAME]


def load(paths):
    records = []
    for source, path in enumerate(resolve(paths)):
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except OSError as error:
            raise ChatOpenError(f"cannot read {path}: {error.strerror or error}") from None
        parsed = [parse_line(path, number, text) for number, text in enumerate(lines, 1) if text.strip()]
        if not parsed:
            raise ChatOpenError(f"{path}: no chat-open records")
        records += [{**record, "source": source, "file": str(path)} for record in parsed]
    return records


def group_opens(records):
    opens = {}
    for record in records:
        opens.setdefault((record["source"], record["bot"], record["open"]), []).append(record)
    return opens


def last_value(records, key):
    return next((record[key] for record in reversed(records) if record.get(key) is not None), None)


def first_ms(records, step):
    return next((record["ms"] for record in records if record["step"] == step), None)


def describe_open(key, records):
    source, bot, count = key
    cached, gateway = last_value(records, "cachedSeq"), last_value(records, "gatewaySeq")
    cache_frame, newest, syncing = first_ms(records, CACHE_FRAME), first_ms(records, NEWEST_FRAME), first_ms(records, SYNCING)
    stale = cached is not None and gateway is not None and cached < gateway
    unannounced = newest is not None and newest > SLOW_NEWEST_MS and (syncing is None or syncing > newest)
    return {
        "source": source,
        "file": records[0]["file"],
        "bot": bot,
        "open": count,
        "cacheFrameMs": cache_frame,
        "newestFrameMs": newest,
        "syncingMs": syncing,
        "cachedSeq": cached,
        "gatewaySeq": gateway,
        "seqGap": gateway - cached if stale else None,
        "stale": stale,
        "slowWithoutSyncing": unannounced,
    }


def step_stats(opens):
    names = [name for name in STEPS if any(first_ms(records, name) is not None for records in opens.values())]
    extra = sorted({record["step"] for records in opens.values() for record in records} - set(STEPS))
    return {
        name: perf_signpost.summarize([ms for records in opens.values() if (ms := first_ms(records, name)) is not None])
        for name in [*names, *extra]
    }


def collect(records):
    opens = group_opens(records)
    described = [describe_open(key, opens[key]) for key in sorted(opens)]
    gaps = [entry["seqGap"] for entry in described if entry["stale"]]
    return {
        "steps": step_stats(opens),
        "opens": described,
        "stale": {"opens": len(gaps), "of": len(described), "gap": perf_signpost.summarize(gaps)},
        "slowWithoutSyncing": [f"{entry['bot']}#{entry['open']}" for entry in described if entry["slowWithoutSyncing"]],
        "neverNewest": [f"{entry['bot']}#{entry['open']}" for entry in described if entry["newestFrameMs"] is None],
        "slowThresholdMs": SLOW_NEWEST_MS,
    }


def step_line(name, stats):
    cells = (perf_signpost.cell(stats[key], 1) for key in ("p50", "p95", "max"))
    return f"  {name:<18} {stats['n']:>4} " + " ".join(f"{value:>9}" for value in cells)


def open_line(entry, show_file):
    label = f"{entry['bot']}#{entry['open']}" + (f" ({Path(entry['file']).parent.name})" if show_file else "")
    seqs = "-" if entry["cachedSeq"] is None and entry["gatewaySeq"] is None else f"{entry['cachedSeq']}->{entry['gatewaySeq']}"
    flags = [name for name, on in (("STALE", entry["stale"]), ("NO-SYNCING", entry["slowWithoutSyncing"])) if on]
    return (
        f"  {label:<28} {perf_signpost.cell(entry['cacheFrameMs'], 1):>11} {perf_signpost.cell(entry['newestFrameMs'], 1):>12} "
        f"{perf_signpost.cell(entry['syncingMs'], 1):>9} {seqs:>12}  {' '.join(flags)}".rstrip()
    )


def render_text(result):
    show_file = len({entry["source"] for entry in result["opens"]}) > 1
    stale = result["stale"]
    lines = [
        f"Chat open trace, {len(result['opens'])} opens; ms since the open tap, nearest-rank percentiles over opens",
        f"  {'step':<18} {'n':>4} {'p50 ms':>9} {'p95 ms':>9} {'max ms':>9}",
        *[step_line(name, stats) for name, stats in result["steps"].items()],
        "",
        f"  {'open':<28} {'cache.frame':>11} {'frame.newest':>12} {'syncing':>9} {'cached->gw':>12}",
        *[open_line(entry, show_file) for entry in result["opens"]],
        "",
        f"stale cache: {stale['opens']} of {stale['of']} opens (cachedSeq < gatewaySeq)"
        + (f", gap p50 {stale['gap']['p50']} max {stale['gap']['max']}" if stale["opens"] else ""),
        f"frame.newest over {result['slowThresholdMs']} ms with no syncing before it: "
        + (", ".join(result["slowWithoutSyncing"]) or "none"),
    ]
    if result["neverNewest"]:
        lines.append(f"opens that never reached frame.newest: {', '.join(result['neverNewest'])}")
    return "\n".join(lines) + "\n"


def render(paths, as_json=False):
    result = collect(load(paths))
    return json.dumps(result, indent=2) + "\n" if as_json else render_text(result)


def main(argv=None):
    parser = argparse.ArgumentParser(description="Summarize pal-chat-open.jsonl traces: step timings, time to the cached and newest frame, stale caches")
    parser.add_argument("paths", nargs="*", help=f"{TRACE_NAME} files or directories holding one (default ${DIRECTORY_KEY}/{TRACE_NAME})")
    parser.add_argument("--json", action="store_true", help="print the summary as JSON")
    args = parser.parse_args(argv)
    try:
        print(render(args.paths, args.json), end="")
    except ChatOpenError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
