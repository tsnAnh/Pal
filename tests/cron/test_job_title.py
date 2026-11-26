import json

import pytest

VIETNAMESE_PROMPT = 'Tóm tắt tin tức công nghệ trong ngày rồi gửi cho tôi. Chỉ lấy nguồn uy tín.'
VIETNAMESE_TITLE = 'Tóm tắt tin tức công nghệ trong ngày rồi gửi cho tôi'
ENGLISH_PROMPT = 'check the build status; report failures only.'
ENGLISH_TITLE = 'Check the build status'


@pytest.mark.parametrize(('name', 'shown'), [
    ('daily_report_job', 'Daily report job'),
    ('weekly-news-digest', 'Weekly news digest'),
    ('3f9a2c1d4e5b6a7f', ENGLISH_TITLE),
    ('9b2d7c1e-4a53-4f0e-9c77-1a2b3c4d5e6f', ENGLISH_TITLE),
    ('Báo cáo buổi sáng', 'Báo cáo buổi sáng'),
    ('Morning digest', 'Morning digest'),
])
def test_a_stored_name_is_shown_readable(name, shown):
    from tools.cronjob_tools import _format_job
    assert _format_job({'id': 'abc123def456', 'name': name, 'prompt': ENGLISH_PROMPT})['name'] == shown


def test_a_hex_name_with_nothing_to_derive_from_never_shows_the_id():
    from cron.job_title import job_title
    assert job_title({'id': 'abc123def456', 'name': 'abc123def456'}) == 'Scheduled task'


@pytest.mark.parametrize(('name', 'prompt', 'stored'), [
    ('daily_report_job', ENGLISH_PROMPT, ENGLISH_TITLE),
    ('weekly-news-digest', VIETNAMESE_PROMPT, VIETNAMESE_TITLE),
    ('3f9a2c1d4e5b6a7f', ENGLISH_PROMPT, ENGLISH_TITLE),
    (None, VIETNAMESE_PROMPT, VIETNAMESE_TITLE),
    ('Báo cáo buổi sáng', ENGLISH_PROMPT, 'Báo cáo buổi sáng'),
    ('Morning digest', VIETNAMESE_PROMPT, 'Morning digest'),
])
def test_a_new_routine_is_stored_with_a_readable_name(name, prompt, stored):
    from cron.jobs import create_job, resolve_job_ref
    job = create_job(prompt, 'every 1h', name=name, deliver='local')
    assert job['name'] == stored
    assert resolve_job_ref(stored)['id'] == job['id']


def test_a_derived_title_is_bounded_and_keeps_whole_words():
    from cron.job_title import TITLE_LIMIT, readable_job_name
    title = readable_job_name('', 'summarize ' + 'every important change ' * 10, creating=True)
    assert len(title) <= TITLE_LIMIT and title.startswith('Summarize every') and title.split()[-1] in {
        'every', 'important', 'change'}


def test_a_stored_raw_name_is_found_by_the_title_shown_for_it():
    from cron.jobs import create_job, resolve_job_ref, update_job
    job = create_job(ENGLISH_PROMPT, 'every 1h', name='Anything', deliver='local')
    update_job(job['id'], {'name': 'weekly-news-digest'})
    assert resolve_job_ref('Weekly news digest')['id'] == job['id']


def test_the_tool_lists_the_shown_name():
    from cron.jobs import create_job, update_job
    from tools.cronjob_tools import cronjob
    job = create_job(ENGLISH_PROMPT, 'every 1h', name='Anything', deliver='local')
    update_job(job['id'], {'name': 'daily_report_job'})
    listed = json.loads(cronjob(action='list'))['jobs']
    assert [row['name'] for row in listed] == ['Daily report job']
