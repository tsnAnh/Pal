import json
import math
import re
from datetime import datetime
from pathlib import Path

SCHEMA = 2
PLATFORMS = ("macOS", "iOS")
THRESHOLD_KEYS = ("hitch", "severe")
COUNT_FIELDS = ("frames", "hitches", "severeHitches")
MILLISECOND_FIELDS = ("worstFrameMs", "hitchMs")
LONG_LIST_MAX = 10
HITCH_LINE = re.compile(r"PAL_HITCH\s+(\{.*\})\s*$")
COMPARED = (
    ("duration_s", "durationSeconds", "{:.1f}"),
    ("hitches_per_min", "hitchesPerMinute", "{:.2f}"),
    ("severe_per_min", "severePerMinute", "{:.2f}"),
    ("hitch_ms_per_s", "hitchMsPerSecond", "{:.2f}"),
    ("worst_frame_ms", "worstFrameMs", "{:.1f}"),
)


class HitchReportError(ValueError):
    pass


def is_number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def require_number(report, field, integer=False):
    if field not in report:
        raise HitchReportError(f"missing field {field!r}")
    value = report[field]
    if integer and (not isinstance(value, int) or isinstance(value, bool)):
        raise HitchReportError(f"field {field!r} must be an integer, got {value!r}")
    if not is_number(value):
        raise HitchReportError(f"field {field!r} must be a finite number, got {value!r}")
    if value < 0:
        raise HitchReportError(f"field {field!r} must not be negative, got {value!r}")
    return value


def validate(report):
    if not isinstance(report, dict):
        raise HitchReportError(f"report must be a JSON object, got {type(report).__name__}")
    if type(report.get("schema")) is not int or report["schema"] != SCHEMA:
        raise HitchReportError(f"unsupported schema {report.get('schema')!r}; this reader understands schema {SCHEMA}")
    if report.get("platform") not in PLATFORMS:
        raise HitchReportError(f"field 'platform' must be one of {PLATFORMS}, got {report.get('platform')!r}")
    started = report.get("startedAt")
    if not isinstance(started, str):
        raise HitchReportError("missing field 'startedAt' (ISO 8601 string)")
    try:
        datetime.fromisoformat(started)
    except ValueError:
        raise HitchReportError(f"field 'startedAt' is not an ISO 8601 timestamp: {started!r}") from None
    if require_number(report, "durationSeconds") <= 0:
        raise HitchReportError("field 'durationSeconds' must be greater than zero")
    for field in COUNT_FIELDS:
        require_number(report, field, integer=True)
    for field in MILLISECOND_FIELDS:
        require_number(report, field)
    if require_number(report, "budgetMs") <= 0:
        raise HitchReportError("field 'budgetMs' must be greater than zero")
    if report["severeHitches"] > report["hitches"]:
        raise HitchReportError("severeHitches exceeds hitches; hitches must include the severe ones")
    if report["hitches"] > report["frames"]:
        raise HitchReportError("hitches exceeds frames")
    thresholds = report.get("thresholdsMs")
    if not isinstance(thresholds, dict):
        raise HitchReportError("missing field 'thresholdsMs'")
    for key in THRESHOLD_KEYS:
        require_number(thresholds, key)
    validate_long_hitches(report)
    return report


def validate_long_hitches(report):
    present = [field for field in ("longHitchThresholdMs", "longHitchCount", "longHitches") if field in report]
    if not present:
        return
    if len(present) != 3:
        raise HitchReportError(f"long hitch fields come together; got only {present}")
    require_number(report, "longHitchThresholdMs")
    count = require_number(report, "longHitchCount", integer=True)
    listed = report["longHitches"]
    if not isinstance(listed, list):
        raise HitchReportError("field 'longHitches' must be a list")
    if len(listed) > min(count, LONG_LIST_MAX):
        raise HitchReportError(f"field 'longHitches' lists {len(listed)} entries for {count} long hitches (at most {LONG_LIST_MAX})")
    if count > report["severeHitches"]:
        raise HitchReportError("longHitchCount exceeds severeHitches; long hitches are severe ones")
    for entry in listed:
        if not isinstance(entry, dict):
            raise HitchReportError(f"field 'longHitches' entries must be objects, got {entry!r}")
        for key in ("atSeconds", "ms"):
            require_number(entry, key)
        if entry["ms"] > report["worstFrameMs"]:
            raise HitchReportError("a long hitch is longer than worstFrameMs")


def extract_line(text):
    found = None
    for line in text.splitlines():
        match = HITCH_LINE.search(line)
        if match:
            found = match.group(1)
    if found is None:
        raise HitchReportError("neither a JSON report nor output holding a 'PAL_HITCH {...}' line")
    try:
        return json.loads(found)
    except ValueError:
        raise HitchReportError("the PAL_HITCH line does not hold valid JSON") from None


def parse(text):
    try:
        data = json.loads(text)
    except ValueError:
        data = extract_line(text)
    return validate(data)


def load(path):
    path = Path(path)
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as error:
        raise HitchReportError(f"cannot read {path}: {error.strerror or error}") from None
    try:
        return parse(text)
    except HitchReportError as error:
        raise HitchReportError(f"{path}: {error}") from None


def longest_hitches(report):
    return sorted(report.get("longHitches", []), key=lambda entry: entry["ms"], reverse=True)[:LONG_LIST_MAX]


def summary(report):
    duration = report["durationSeconds"]
    return {
        "durationSeconds": duration,
        "frames": report["frames"],
        "budgetMs": report["budgetMs"],
        "hitchesPerMinute": report["hitches"] / duration * 60,
        "severePerMinute": report["severeHitches"] / duration * 60,
        "hitchMsPerSecond": report["hitchMs"] / (duration * 1000) * 1000,
        "worstFrameMs": report["worstFrameMs"],
        "longHitchCount": report.get("longHitchCount"),
        "longestHitches": longest_hitches(report),
    }


def render_summary(report):
    stats = summary(report)
    thresholds = report["thresholdsMs"]
    lines = [
        f"{report['platform']} run started {report['startedAt']}, {stats['durationSeconds']:.1f} s, {report['frames']} frames "
        f"(frame budget {report['budgetMs']:.2f} ms, hitch > {thresholds['hitch']:.2f} ms, severe > {thresholds['severe']:g} ms)",
        f"  hitches: {report['hitches']} ({stats['hitchesPerMinute']:.2f}/min), severe: {report['severeHitches']} ({stats['severePerMinute']:.2f}/min)",
        f"  hitch time: {stats['hitchMsPerSecond']:.2f} ms per second",
        f"  worst frame: {stats['worstFrameMs']:.1f} ms",
    ]
    if stats["longHitchCount"] is not None:
        lines.append(f"  long hitches (> {report['longHitchThresholdMs']:g} ms): {stats['longHitchCount']}")
        lines += [f"    t={entry['atSeconds']:.2f} s  {entry['ms']:.1f} ms" for entry in stats["longestHitches"]]
    return "\n".join(lines) + "\n"


def change_cell(before, after):
    if before == 0:
        return "+0.0%" if after == 0 else "n/a"
    return f"{(after - before) / before * 100:+.1f}%"


def compare(before_report, after_report):
    before, after = summary(before_report), summary(after_report)
    lines = [f"{'metric':<20} {'before':>12} {'after':>12} {'change':>9}"]
    for label, key, template in COMPARED:
        lines.append(f"{label:<20} {template.format(before[key]):>12} {template.format(after[key]):>12} {change_cell(before[key], after[key]):>9}")
    if before_report["platform"] != after_report["platform"]:
        lines.append(f"note: platforms differ ({before_report['platform']} vs {after_report['platform']}); the numbers are not comparable")
    if abs(before["budgetMs"] - after["budgetMs"]) > 0.5:
        lines.append(f"note: frame budgets differ ({before['budgetMs']:.2f} ms vs {after['budgetMs']:.2f} ms); the displays ran at different refresh rates")
    return "\n".join(lines) + "\n"


def render(report_path, after_path=None):
    before = load(report_path)
    if after_path is None:
        return render_summary(before)
    return compare(before, load(after_path))
