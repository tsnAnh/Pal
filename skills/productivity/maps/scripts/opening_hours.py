import re
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone, UTC
from typing import Optional

try:
    from zoneinfo import ZoneInfo
except ImportError:
    ZoneInfo = None

DAYS = ("Mo", "Tu", "We", "Th", "Fr", "Sa", "Su")
DAY_NAMES = ("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")
DAY_INDEX = {code: index for index, code in enumerate(DAYS)}
HORIZON_DAYS = 8
MINUTES_PER_DAY = 1440

NO_HOURS_NOTE = (
    "OpenStreetMap has no opening hours for this place. "
    "Call or check the venue's website before going."
)

_DAY = "(?:Mo|Tu|We|Th|Fr|Sa|Su|PH|SH)"
_DAY_SELECTOR = rf"{_DAY}(?:\s*-\s*(?:Mo|Tu|We|Th|Fr|Sa|Su))?"
_RULE = re.compile(
    rf"^(?P<days>{_DAY_SELECTOR}(?:\s*,\s*{_DAY_SELECTOR})*)?\s*(?P<rest>.*)$"
)
_TIME_RANGE = re.compile(r"^(\d{1,2}):(\d{2})\s*-\s*(\d{1,2}):(\d{2})$")
_OFF_WORDS = {"off", "closed"}


class UnsupportedOpeningHours(ValueError):
    pass


@dataclass(frozen=True)
class Schedule:
    days: tuple
    holidays_ignored: bool = False


def _expand_days(selector):
    indexes = []
    holidays = False
    for part in selector.split(","):
        part = part.strip()
        if part in ("PH", "SH"):
            holidays = True
            continue
        if "-" in part:
            first, last = (token.strip() for token in part.split("-"))
            start, end = DAY_INDEX[first], DAY_INDEX[last]
            span = (end - start) % 7
            indexes.extend((start + offset) % 7 for offset in range(span + 1))
        else:
            indexes.append(DAY_INDEX[part])
    return indexes, holidays


def _parse_time_ranges(text):
    ranges = []
    for chunk in text.split(","):
        match = _TIME_RANGE.match(chunk.strip())
        if not match:
            raise UnsupportedOpeningHours(f"unsupported time selector: {chunk.strip()!r}")
        start_h, start_m, end_h, end_m = (int(group) for group in match.groups())
        if start_h > 23 or start_m > 59 or end_h > 24 or end_m > 59:
            raise UnsupportedOpeningHours(f"time out of range: {chunk.strip()!r}")
        end_total = end_h * 60 + end_m
        if end_total > MINUTES_PER_DAY:
            raise UnsupportedOpeningHours(f"time out of range: {chunk.strip()!r}")
        start = start_h * 60 + start_m
        if end_total == start:
            raise UnsupportedOpeningHours(f"empty time range: {chunk.strip()!r}")
        if end_total < start:
            end_total += MINUTES_PER_DAY
        ranges.append((start, end_total))
    return tuple(sorted(ranges))


def parse_opening_hours(raw):
    if raw is None or not str(raw).strip():
        raise UnsupportedOpeningHours("empty opening_hours")
    text = str(raw).strip()
    if text == "24/7":
        full = ((0, MINUTES_PER_DAY),)
        return Schedule(days=(full,) * 7)

    days = [()] * 7
    holidays_ignored = False
    for rule in (piece.strip() for piece in text.split(";")):
        if not rule:
            continue
        match = _RULE.match(rule)
        rest = (match.group("rest") or "").strip()
        if not rest:
            raise UnsupportedOpeningHours(f"unsupported rule: {rule!r}")
        if match.group("days"):
            targets, holidays = _expand_days(match.group("days"))
        else:
            targets, holidays = list(range(7)), False
        if not targets and holidays:
            holidays_ignored = True
            continue
        if rest.lower() in _OFF_WORDS:
            ranges = ()
        elif rest == "24/7":
            ranges = ((0, MINUTES_PER_DAY),)
        else:
            ranges = _parse_time_ranges(rest)
        for index in targets:
            days[index] = ranges
        holidays_ignored = holidays_ignored or holidays
    return Schedule(days=tuple(days), holidays_ignored=holidays_ignored)


def _merged_intervals(schedule, now):
    midnight = datetime(now.year, now.month, now.day)
    intervals = []
    for offset in range(-1, HORIZON_DAYS + 1):
        day = midnight + timedelta(days=offset)
        for start, end in schedule.days[day.weekday()]:
            intervals.append((day + timedelta(minutes=start), day + timedelta(minutes=end)))
    intervals.sort()
    merged = []
    for start, end in intervals:
        if merged and start <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(merged[-1][1], end))
        else:
            merged.append((start, end))
    return merged


def format_minutes(total):
    if total == MINUTES_PER_DAY:
        return "24:00"
    total %= MINUTES_PER_DAY
    return f"{total // 60:02d}:{total % 60:02d}"


def format_when(moment, now):
    days_ahead = (moment.date() - now.date()).days
    if moment.hour == 0 and moment.minute == 0 and days_ahead == 1:
        return "at midnight"
    clock = moment.strftime("%H:%M")
    if days_ahead == 0:
        return f"at {clock}"
    if days_ahead == 1:
        return f"tomorrow at {clock}"
    return f"{DAY_NAMES[moment.weekday()]} at {clock}"


def _today_text(schedule, now):
    ranges = schedule.days[now.weekday()]
    if not ranges:
        return "closed"
    if ranges == ((0, MINUTES_PER_DAY),):
        return "open 24 hours"
    return ", ".join(f"{format_minutes(s)}-{format_minutes(e)}" for s, e in ranges)


def evaluate_schedule(schedule, now):
    merged = _merged_intervals(schedule, now)
    horizon_end = datetime(now.year, now.month, now.day) + timedelta(days=HORIZON_DAYS)
    current = next(((s, e) for s, e in merged if s <= now < e), None)
    if current is not None:
        if current[1] >= horizon_end:
            summary = "Open now, open around the clock"
        else:
            summary = f"Open now, closes {format_when(current[1], now)}"
        state, open_now = "open", True
    else:
        upcoming = next((s for s, _ in merged if s > now), None)
        if upcoming is None:
            summary = "Closed now, no opening times in the next week"
        else:
            summary = f"Closed now, opens {format_when(upcoming, now)}"
        state, open_now = "closed", False
    result = {
        "state": state,
        "open_now": open_now,
        "summary": summary,
        "today": _today_text(schedule, now),
    }
    if schedule.holidays_ignored:
        result["note"] = "Public and school holiday rules are not applied."
    return result


def local_now(tz_name, now_utc):
    if not tz_name or ZoneInfo is None:
        return None
    try:
        zone = ZoneInfo(tz_name)
    except (KeyError, ValueError, OSError):
        return None
    return now_utc.astimezone(zone).replace(tzinfo=None)


def unknown_hours(summary, raw=None, tz_name=None, note=None):
    result = {"state": "unknown", "open_now": None, "summary": summary}
    if raw:
        result["raw"] = raw
    if tz_name:
        result["timezone"] = tz_name
    if note:
        result["note"] = note
    return result


def describe_hours(raw, tz_name, now_utc: Optional[datetime] = None):
    if raw is None or not str(raw).strip():
        return unknown_hours(NO_HOURS_NOTE, tz_name=tz_name)
    now_utc = now_utc or datetime.now(UTC)
    try:
        schedule = parse_opening_hours(raw)
    except UnsupportedOpeningHours as exc:
        return unknown_hours(
            "Opening hours use a format that could not be evaluated; read the raw value.",
            raw=raw, tz_name=tz_name, note=str(exc),
        )
    now_local = local_now(tz_name, now_utc)
    if now_local is None:
        return unknown_hours(
            "Timezone for this place could not be determined, so open-now cannot be "
            "computed; the raw hours are in the place's local time.",
            raw=raw, tz_name=tz_name,
        )
    result = evaluate_schedule(schedule, now_local)
    result["raw"] = raw
    result["timezone"] = tz_name
    return result
