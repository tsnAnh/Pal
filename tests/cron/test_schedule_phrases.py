import pytest

from cron.schedule_phrases import (
    ERROR_EMPTY,
    ERROR_TOO_FREQUENT,
    ERROR_UNRECOGNIZED,
    MIN_INTERVAL_MINUTES,
    ScheduleRejected,
    normalize_schedule_phrase,
    resolve_routine_schedule,
)


@pytest.mark.parametrize(
    ("phrase", "schedule", "kind"),
    [
        ("every weekday at 9am", "0 9 * * 1-5", "cron"),
        ("Every Weekday at 9AM.", "0 9 * * 1-5", "cron"),
        ("9am every weekday", "0 9 * * 1-5", "cron"),
        ("at 6:30 pm every day", "30 18 * * *", "cron"),
        ("each monday at noon", "0 12 * * 1", "cron"),
        ("every monday and friday at 8am", "0 8 * * 1,5", "cron"),
        ("daily at 9am", "0 9 * * *", "cron"),
        ("weekly on monday at 9am", "0 9 * * 1", "cron"),
        ("every week on friday 4:15pm", "15 16 * * 5", "cron"),
        ("every month on the 15th at 9am", "0 9 15 * *", "cron"),
        ("monthly on the 1st at 7:30am", "30 7 1 * *", "cron"),
        ("on the 3rd of every month at 5pm", "0 17 3 * *", "cron"),
        ("every 2 hours", "every 120m", "interval"),
        ("every two hours", "every 120m", "interval"),
        ("every other day", "every 2880m", "interval"),
        ("hourly", "every 60m", "interval"),
        ("every hour", "every 60m", "interval"),
        ("every half hour", "every 30m", "interval"),
        ("every 5 minutes", "every 5m", "interval"),
        ("every 1 day", "every 1440m", "interval"),
        ("0 9 * * 1-5", "0 9 * * 1-5", "cron"),
        ("every 3h", "every 180m", "interval"),
        ("in 30m", "in 30m", "once"),
    ],
)
def test_phrases_normalize_to_a_stored_schedule(phrase, schedule, kind):
    resolved = resolve_routine_schedule(phrase)
    assert resolved["schedule"] == schedule
    assert resolved["kind"] == kind
    assert resolved["next_run_at"]


def test_a_one_shot_delay_is_not_a_cadence_and_may_be_shorter_than_the_minimum():
    resolved = resolve_routine_schedule("in 2m")
    assert resolved["kind"] == "once" and resolved["schedule"] == "in 2m"


def test_normalized_schedule_is_stable_when_resolved_again():
    first = resolve_routine_schedule("every weekday at 9am")["schedule"]
    assert resolve_routine_schedule(first)["schedule"] == first
    interval = resolve_routine_schedule("every two hours")["schedule"]
    assert resolve_routine_schedule(interval)["schedule"] == interval


@pytest.mark.parametrize("phrase", ["every minute", "every 1 minute", "every 4m", "every 2 minutes", "*/2 * * * *",
                                    "* * * * *", "0,3 9 * * *"])
def test_intervals_under_the_minimum_are_rejected(phrase):
    with pytest.raises(ScheduleRejected) as rejected:
        resolve_routine_schedule(phrase)
    assert rejected.value.code == ERROR_TOO_FREQUENT
    assert str(MIN_INTERVAL_MINUTES) in str(rejected.value)


@pytest.mark.parametrize("phrase", ["every 5 minutes", "*/5 * * * *", "0,10 9 * * *"])
def test_minimum_interval_is_inclusive(phrase):
    assert resolve_routine_schedule(phrase)["next_run_at"]


@pytest.mark.parametrize("phrase", ["", "   ", None])
def test_blank_schedule_is_rejected(phrase):
    with pytest.raises(ScheduleRejected) as rejected:
        resolve_routine_schedule(phrase)
    assert rejected.value.code == ERROR_EMPTY


@pytest.mark.parametrize("phrase", ["whenever you feel like it", "every full moon", "tomorrowish", "every blue day at 9am"])
def test_unintelligible_phrases_are_rejected_without_leaking_parser_text(phrase):
    with pytest.raises(ScheduleRejected) as rejected:
        resolve_routine_schedule(phrase)
    assert rejected.value.code == ERROR_UNRECOGNIZED
    assert "Interval:" not in str(rejected.value)


@pytest.mark.parametrize("phrase", ["every month on the 31st at 9am", "monthly on the 0th at 9am"])
def test_monthly_days_outside_every_month_are_rejected(phrase):
    with pytest.raises(ScheduleRejected):
        resolve_routine_schedule(phrase)


def test_unmatched_text_has_no_normal_form():
    assert normalize_schedule_phrase("0 9 * * *") is None
    assert normalize_schedule_phrase("every 30m") is None
