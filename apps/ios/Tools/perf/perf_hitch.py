import json
import math
import re
from datetime import datetime
from pathlib import Path

SCHEMA = 1
PLATFORMS = ("macOS", "iOS")
THRESHOLD_KEYS = ("hitch", "severe")
COUNT_FIELDS = ("frames", "hitches", "severeHitches")
MILLISECOND_FIELDS = ("worstFrameMs", "hitchMs")
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
    if report["severeHitches"] > report["hitches"]:
        raise HitchReportError("severeHitches exceeds hitches; hitches must include the severe ones")
    if report["hitches"] > report["frames"]:
        raise HitchReportError("hitches exceeds frames")
    thresholds = report.get("thresholdsMs")
    if not isinstance(thresholds, dict):
        raise HitchReportError("missing field 'thresholdsMs'")
    for key in THRESHOLD_KEYS:
        require_number(thresholds, key)
    return report


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


def summary(report):
    duration = report["durationSeconds"]
    return {
        "durationSeconds": duration,
        "frames": report["frames"],
        "hitchesPerMinute": report["hitches"] / duration * 60,
        "severePerMinute": report["severeHitches"] / duration * 60,
        "hitchMsPerSecond": report["hitchMs"] / (duration * 1000) * 1000,
        "worstFrameMs": report["worstFrameMs"],
    }


def render_summary(report):
    stats = summary(report)
    thresholds = report["thresholdsMs"]
    return "\n".join([
        f"{report['platform']} run started {report['startedAt']}, {stats['durationSeconds']:.1f} s, {report['frames']} frames "
        f"(hitch > {thresholds['hitch']:g} ms, severe > {thresholds['severe']:g} ms)",
        f"  hitches: {report['hitches']} ({stats['hitchesPerMinute']:.2f}/min), severe: {report['severeHitches']} ({stats['severePerMinute']:.2f}/min)",
        f"  hitch time: {stats['hitchMsPerSecond']:.2f} ms per second",
        f"  worst frame: {stats['worstFrameMs']:.1f} ms",
    ]) + "\n"


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
    return "\n".join(lines) + "\n"


def render(report_path, after_path=None):
    before = load(report_path)
    if after_path is None:
        return render_summary(before)
    return compare(before, load(after_path))
