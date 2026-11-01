from __future__ import annotations

import re
from typing import Any, Callable, Optional

MIN_INTERVAL_MINUTES = 5
_CADENCE_SAMPLES = 8

ERROR_EMPTY = "empty"
ERROR_TOO_FREQUENT = "too_frequent"
ERROR_UNRECOGNIZED = "unrecognized"
ERROR_INVALID = "invalid"

_NUMBER_WORDS = {
    "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
    "seven": 7, "eight": 8, "nine": 9, "ten": 10, "twelve": 12,
}
_NUMBER = r"(\d{1,4}|" + "|".join(_NUMBER_WORDS) + r")"
_UNIT = r"(minutes?|mins?|hours?|hrs?|days?)"
_TIME = r"((?:\d{1,2}(?::\d{2})?\s?(?:am|pm)?)|noon|midday|midnight)"
_WEEKDAYS = (
    r"(?:mon(?:day)?|tue(?:s|sday)?|wed(?:s|nesday)?|thu(?:r|rs|rsday)?|fri(?:day)?|sat(?:urday)?|sun(?:day)?)")
_DAY_LIST = rf"(?:{_WEEKDAYS}(?:(?:,|\s)+(?:and\s+)?{_WEEKDAYS})*)"
_DAYSPEC = rf"(day|weekdays?|weekends?|{_DAY_LIST})"
_ORDINAL = r"(\d{1,2})(?:st|nd|rd|th)?"


class ScheduleRejected(ValueError):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


def _count(token: str) -> int:
    return _NUMBER_WORDS.get(token) or int(token)


def _unit_letter(unit: str) -> str:
    return unit[0]


def _clean(text: str) -> str:
    cleaned = re.sub(r"\s+", " ", str(text or "").strip().lower())
    return cleaned.rstrip(".!")


def _interval(count: int, unit: str) -> str:
    return f"every {count}{_unit_letter(unit)}"


def _numbered_interval(match: re.Match) -> str:
    return _interval(_count(match.group(1)), match.group(2))


def _every_other(match: re.Match) -> str:
    return _interval(2, match.group(1))


def _half_hour(_: re.Match) -> str:
    return "every 30m"


def _hourly(_: re.Match) -> str:
    return "every 1h"


def _day_first(match: re.Match) -> str:
    return f"every {match.group(1)} at {match.group(2).replace(' ', '')}"


def _time_first(match: re.Match) -> str:
    return f"every {match.group(2)} at {match.group(1).replace(' ', '')}"


def _weekly(match: re.Match) -> str:
    return f"every {match.group(1)} at {match.group(2).replace(' ', '')}"


def _clock(time_text: str) -> tuple[int, int]:
    from cron.jobs import _parse_clock_time

    parsed = _parse_clock_time(time_text)
    if parsed is None:
        raise ScheduleRejected(ERROR_INVALID, f"'{time_text}' is not a time of day.")
    return parsed


def _monthly(match: re.Match) -> str:
    day = int(match.group(1))
    if not 1 <= day <= 28:
        raise ScheduleRejected(
            ERROR_INVALID, "Monthly routines can run on days 1 to 28 so every month has that day.")
    hour, minute = _clock(match.group(2))
    return f"{minute} {hour} {day} * *"


_RULES: tuple[tuple[re.Pattern, Callable[[re.Match], str]], ...] = tuple(
    (re.compile(pattern), builder) for pattern, builder in (
        (rf"^(?:every|each) {_NUMBER} {_UNIT}$", _numbered_interval),
        (r"^(?:every|each) other (hour|day)$", _every_other),
        (r"^(?:every|each) half(?: an)? hour$", _half_hour),
        (r"^hourly$", _hourly),
        (rf"^(?:each|every) {_DAYSPEC}(?: at)? {_TIME}$", _day_first),
        (rf"^(?:at )?{_TIME} (?:every |each |on )?{_DAYSPEC}$", _time_first),
        (rf"^(?:every week|weekly)(?: on)? ({_WEEKDAYS})(?: at)? {_TIME}$", _weekly),
        (rf"^(?:every month|monthly)(?: on)?(?: the)? {_ORDINAL}(?: day)?(?: at)? {_TIME}$", _monthly),
        (rf"^on the {_ORDINAL} (?:of )?(?:every|each) month(?: at)? {_TIME}$", _monthly),
    )
)


def normalize_schedule_phrase(text: str) -> Optional[str]:
    """Rewrite a plain-language phrase into a form ``cron.jobs.parse_schedule`` accepts, or None
    when no rule applies (the caller then hands the original text to the parser unchanged)."""
    cleaned = _clean(text)
    for pattern, builder in _RULES:
        match = pattern.match(cleaned)
        if match:
            return builder(match)
    return None


def _shortest_gap_minutes(expr: str) -> float:
    from cron import jobs
    from hermes_time import now as hermes_now

    jobs._ensure_croniter()
    iterator = jobs.croniter(expr, hermes_now())
    previous = iterator.get_next(float)
    shortest = float("inf")
    for _ in range(_CADENCE_SAMPLES):
        current = iterator.get_next(float)
        shortest = min(shortest, (current - previous) / 60)
        previous = current
    return shortest


def _too_frequent() -> ScheduleRejected:
    return ScheduleRejected(
        ERROR_TOO_FREQUENT, f"Routines can run at most once every {MIN_INTERVAL_MINUTES} minutes.")


def _enforce_minimum_interval(parsed: dict[str, Any]) -> None:
    kind = parsed.get("kind")
    if kind == "interval" and int(parsed.get("minutes") or 0) < MIN_INTERVAL_MINUTES:
        raise _too_frequent()
    if kind == "cron" and _shortest_gap_minutes(str(parsed["expr"])) < MIN_INTERVAL_MINUTES:
        raise _too_frequent()


def _canonical_schedule(parsed: dict[str, Any], fallback: str) -> str:
    if parsed.get("kind") == "cron":
        return str(parsed["expr"])
    if parsed.get("kind") == "interval":
        return f"every {int(parsed['minutes'])}m"
    return fallback


def _next_run_iso(parsed: dict[str, Any]) -> Optional[str]:
    from cron.jobs import compute_next_run

    return compute_next_run(parsed)


def resolve_routine_schedule(text: str) -> dict[str, Any]:
    """Validate a routine's schedule as typed (phrase, interval or cron) and return its normalized
    form: ``{"schedule", "accepted_as", "kind", "next_run_at"}`` (``accepted_as`` is the text the parser took,
    which keeps the human wording in a stored job's display). Raises ``ScheduleRejected`` with a stable ``code``
    (empty, too_frequent, unrecognized, invalid) so a client can localize the reason."""
    from cron.jobs import parse_schedule

    raw = str(text or "").strip()
    if not raw:
        raise ScheduleRejected(ERROR_EMPTY, "Choose when this routine should run.")
    candidate = normalize_schedule_phrase(raw) or raw
    try:
        parsed = parse_schedule(candidate)
    except ValueError as exc:
        code = ERROR_UNRECOGNIZED if candidate == raw and "Invalid" in str(exc) else ERROR_INVALID
        raise ScheduleRejected(code, "That schedule was not understood.") from exc
    _enforce_minimum_interval(parsed)
    return {
        "schedule": _canonical_schedule(parsed, candidate),
        "accepted_as": candidate,
        "kind": parsed["kind"],
        "next_run_at": _next_run_iso(parsed),
    }


__all__ = [
    "ERROR_EMPTY", "ERROR_INVALID", "ERROR_TOO_FREQUENT", "ERROR_UNRECOGNIZED", "MIN_INTERVAL_MINUTES",
    "ScheduleRejected", "normalize_schedule_phrase", "resolve_routine_schedule",
]
