from __future__ import annotations

import re
from datetime import datetime
from typing import Any, Optional

_WEEKDAY_NAMES = ("Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday")
_DAY_ALIASES = {name[:3].lower(): index for index, name in enumerate(_WEEKDAY_NAMES)}
_WEEKDAYS = frozenset(range(5))
_WEEKEND = frozenset({5, 6})
_ALL_DAYS = frozenset(range(7))
_NUMBER = re.compile(r"^\d{1,2}$")
_STEP = re.compile(r"^\*/(\d{1,2})$")
CUSTOM_SCHEDULE = "Custom schedule"


def _clock(hour: int, minute: int) -> str:
    suffix = "AM" if hour < 12 else "PM"
    return f"{hour % 12 or 12}:{minute:02d} {suffix}"


_ORDINAL_SUFFIXES = {1: "st", 2: "nd", 3: "rd"}


def _ordinal(day: int) -> str:
    suffix = "th" if 10 <= day % 100 <= 20 else _ORDINAL_SUFFIXES.get(day % 10, "th")
    return f"{day}{suffix}"


def _day_index(token: str) -> Optional[int]:
    token = token.strip().lower()
    if _NUMBER.match(token):
        value = int(token)
        return None if value > 7 else (value - 1) % 7
    return _DAY_ALIASES.get(token[:3])


def _day_range(part: str) -> Optional[set[int]]:
    first, dash, last = part.partition("-")
    start = _day_index(first)
    if start is None:
        return None
    if not dash:
        return {start}
    end = _day_index(last)
    if end is None:
        return None
    span = (end - start) % 7
    return {(start + step) % 7 for step in range(span + 1)}


def _weekdays_of(field: str) -> Optional[frozenset[int]]:
    if field == "*":
        return _ALL_DAYS
    days: set[int] = set()
    for part in field.split(","):
        resolved = _day_range(part)
        if resolved is None:
            return None
        days |= resolved
    return frozenset(days)


def _plural_days(days: frozenset[int]) -> str:
    names = [f"{_WEEKDAY_NAMES[index]}s" for index in sorted(days)]
    return names[0] if len(names) == 1 else f"{', '.join(names[:-1])} and {names[-1]}"


def _day_phrase(days: frozenset[int]) -> Optional[str]:
    if days == _ALL_DAYS:
        return "Every day"
    if days == _WEEKDAYS:
        return "Weekdays"
    if days == _WEEKEND:
        return "Weekends"
    return _plural_days(days) if days else None


def _fixed(field: str, upper: int) -> Optional[int]:
    return int(field) if _NUMBER.match(field) and int(field) <= upper else None


def _stepped(minute: str, hour: str) -> Optional[str]:
    minute_step, hour_step = _STEP.match(minute), _STEP.match(hour)
    if hour == "*" and minute_step and int(minute_step.group(1)) > 0:
        count = int(minute_step.group(1))
        return "Every minute" if count == 1 else f"Every {count} minutes"
    if minute_step is None and hour_step and int(hour_step.group(1)) > 0 and _fixed(minute, 59) == 0:
        count = int(hour_step.group(1))
        return "Every hour" if count == 1 else f"Every {count} hours"
    return None


def _describe_cron(expression: str) -> str:
    fields = expression.split()
    if len(fields) != 5:
        return CUSTOM_SCHEDULE
    minute, hour, day_of_month, month, day_of_week = fields
    if stepped := _stepped(minute, hour):
        return stepped if (day_of_month, month, day_of_week) == ("*", "*", "*") else CUSTOM_SCHEDULE
    minute_value = _fixed(minute, 59)
    if minute_value is None or month != "*":
        return CUSTOM_SCHEDULE
    hour_value = _fixed(hour, 23)
    if hour == "*":
        return f"Every hour at :{minute_value:02d}" if (day_of_month, day_of_week) == ("*", "*") else CUSTOM_SCHEDULE
    if hour_value is None:
        return CUSTOM_SCHEDULE
    when = f"around {_clock(hour_value, minute_value)}"
    if day_of_month != "*":
        day = _fixed(day_of_month, 31)
        if day is None or not 1 <= day <= 31 or day_of_week != "*":
            return CUSTOM_SCHEDULE
        return f"Monthly on the {_ordinal(day)} {when}"
    days = _weekdays_of(day_of_week)
    phrase = _day_phrase(days) if days is not None else None
    return f"{phrase} {when}" if phrase else CUSTOM_SCHEDULE


def _describe_interval(minutes: int) -> str:
    if minutes <= 0:
        return CUSTOM_SCHEDULE
    for size, unit in ((1440, "day"), (60, "hour"), (1, "minute")):
        if minutes % size == 0:
            count = minutes // size
            return f"Every {unit}" if count == 1 else f"Every {count} {unit}s"
    return CUSTOM_SCHEDULE


def _describe_once(run_at: Any) -> str:
    try:
        moment = datetime.fromisoformat(str(run_at))
    except ValueError:
        return "Once"
    return f"Once on {moment.strftime('%b')} {moment.day} at {_clock(moment.hour, moment.minute)}"


def describe_schedule(schedule: Any) -> str:
    """Plain-English text for a parsed job ``schedule`` dict (``kind`` cron / interval / once)."""
    if not isinstance(schedule, dict):
        return CUSTOM_SCHEDULE
    kind = schedule.get("kind")
    if kind == "cron":
        return _describe_cron(str(schedule.get("expr") or ""))
    if kind == "interval":
        minutes = schedule.get("minutes")
        return _describe_interval(minutes) if isinstance(minutes, int) else CUSTOM_SCHEDULE
    if kind == "once":
        return _describe_once(schedule.get("run_at"))
    return CUSTOM_SCHEDULE


__all__ = ["CUSTOM_SCHEDULE", "describe_schedule"]
