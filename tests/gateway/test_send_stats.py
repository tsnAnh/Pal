"""The ``send_trace`` ledger behind ``hermes diag send-stats``: every admitted and steer_drained event is a
journal-visible line and a bounded ledger row carrying ids, statuses, reasons and milliseconds only."""
import logging
import sqlite3

import pytest

from gateway import send_stats

NOW = 1_800_000_000.0
HOUR = 3600.0


class Journal(logging.Handler):
    """A handler at the level the systemd journal handler runs at (the gateway's stderr is WARNING)."""

    def __init__(self):
        super().__init__(logging.WARNING)
        self.lines = []

    def emit(self, record):
        self.lines.append((record.name, record.levelno, record.getMessage()))


@pytest.fixture
def journal():
    handler = Journal()
    root = logging.getLogger()
    root.addHandler(handler)
    yield handler
    root.removeHandler(handler)


@pytest.fixture
def root(tmp_path):
    return tmp_path / 'hermes'


def fill(root, events):
    for age_hours, kind, status, why, ms in events:
        send_stats.record(kind, 'adm', status, why, ms, root=root, now=NOW - age_hours * HOUR)


def test_both_trace_lines_reach_a_warning_level_journal_handler(journal, root):
    send_stats.admitted('adm-1', 'steered', 'absorbed', 12.7, root=root)
    send_stats.steer_drained('adm-1', 1500.2, root=root)
    assert journal.lines == [
        ('gateway.send_trace', logging.WARNING, 'send_trace admitted admission=adm-1 status=steered why=absorbed absorb_ms=12'),
        ('gateway.send_trace', logging.WARNING, 'send_trace steer_drained admission=adm-1 wait_ms=1500'),
    ]


def test_an_untouched_admission_is_traced_as_untouched(journal, root):
    send_stats.admitted('adm-2', None, 'not_bot_chat', 0.4, root=root)
    assert 'status=untouched why=not_bot_chat absorb_ms=0' in journal.lines[0][2]
    assert send_stats.summary(hours=1, root=root)['by_status']['untouched'] == 1


def test_the_summary_counts_by_status_and_why_with_min_median_max(root):
    fill(root, [
        (1, 'admitted', 'steered', 'absorbed', 10),
        (2, 'admitted', 'steered', 'absorbed', 20),
        (3, 'admitted', 'steered', 'absorbed', 60),
        (4, 'admitted', 'queued', 'not_steerable', 4),
        (5, 'admitted', 'turn', 'idle', 6),
        (5, 'admitted', 'untouched', 'not_bot_chat', 2),
        (1, 'drained', '', '', 1000),
        (2, 'drained', '', '', 3000),
    ])
    result = send_stats.summary(hours=24, root=root, now=NOW)
    assert result == {
        'window_hours': 24,
        'admitted': 6,
        'by_status': {'steered': 3, 'queued': 1, 'turn': 1, 'untouched': 1},
        'by_why': {'absorbed': 3, 'not_steerable': 1, 'idle': 1, 'not_bot_chat': 1},
        'absorb_ms': {'min': 2, 'median': 8.0, 'max': 60},
        'steer_drained': 2,
        'wait_ms': {'min': 1000, 'median': 2000.0, 'max': 3000},
    }


def test_the_window_cuts_older_events_and_an_empty_window_has_zero_counts_and_no_timings(root):
    fill(root, [(1, 'admitted', 'steered', 'absorbed', 10), (30, 'admitted', 'steered', 'absorbed', 999),
                (30, 'drained', '', '', 999)])
    recent = send_stats.summary(hours=24, root=root, now=NOW)
    assert (recent['admitted'], recent['absorb_ms'], recent['steer_drained'], recent['wait_ms']) == (
        1, {'min': 10, 'median': 10, 'max': 10}, 0, None)
    empty = send_stats.summary(hours=1, root=root, now=NOW + 40 * HOUR)
    assert empty['by_status'] == {'steered': 0, 'queued': 0, 'turn': 0, 'untouched': 0}
    assert (empty['admitted'], empty['absorb_ms'], empty['by_why']) == (0, None, {})


def test_hours_are_capped_to_the_retention_window(root):
    fill(root, [(1, 'admitted', 'turn', 'idle', 1)])
    assert send_stats.summary(hours=99999, root=root, now=NOW)['window_hours'] == send_stats.MAX_HOURS
    assert send_stats.summary(hours=0, root=root, now=NOW)['window_hours'] == 1


def test_a_host_with_no_ledger_reads_none_and_reading_never_creates_one(root):
    assert send_stats.summary(hours=24, root=root) is None
    assert not (root / send_stats.DB_NAME).exists()


def test_reading_changes_nothing_and_the_read_connection_refuses_writes(root):
    fill(root, [(1, 'admitted', 'steered', 'absorbed', 10)])
    path = root / send_stats.DB_NAME
    before = (path.stat().st_mtime_ns, path.stat().st_size)
    send_stats.summary(hours=24, root=root, now=NOW)
    send_stats.summary(hours=24, root=root, now=NOW)
    assert (path.stat().st_mtime_ns, path.stat().st_size) == before
    conn = send_stats.open_readonly(path)
    try:
        with pytest.raises(sqlite3.OperationalError):
            conn.execute("INSERT INTO events (ts, kind) VALUES (1, 'admitted')")
    finally:
        conn.close()


def test_the_ledger_is_bounded_by_row_count_and_retention(root, monkeypatch):
    monkeypatch.setattr(send_stats, 'MAX_ROWS', 3)
    fill(root, [(10 + age, 'admitted', 'turn', 'idle', age) for age in range(8)])
    fill(root, [(0, 'admitted', 'turn', 'idle', 77)])
    conn = send_stats.open_readonly(root / send_stats.DB_NAME)
    try:
        kept = [row[0] for row in conn.execute('SELECT ms FROM events ORDER BY id')]
    finally:
        conn.close()
    assert len(kept) <= 4 and kept[-1] == 77


def test_a_ledger_that_cannot_be_written_never_breaks_the_send_path(journal, tmp_path):
    blocked = tmp_path / 'file'
    blocked.write_text('x')
    send_stats.admitted('adm-3', 'steered', 'absorbed', 1, root=blocked / 'sub')
    send_stats.steer_drained('adm-3', 1, root=blocked / 'sub')
    assert [line[2].split(' admission=')[0] for line in journal.lines if ' admission=' in line[2]] == [
        'send_trace admitted', 'send_trace steer_drained']


def test_free_text_fields_are_capped_before_they_reach_the_ledger(root):
    send_stats.admitted('adm-4', 'queued', 'x' * 500, 3, root=root)
    conn = send_stats.open_readonly(root / send_stats.DB_NAME)
    try:
        assert [len(row[0]) for row in conn.execute('SELECT why FROM events')] == [send_stats.MAX_FIELD]
    finally:
        conn.close()
