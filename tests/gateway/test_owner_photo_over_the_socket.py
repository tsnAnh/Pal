import pytest
import pytest_asyncio

from tests.fixtures.owner_photo_images import b64, gif, png
from tests.gateway.bots_harness import READ, bots_state, failure, install_state
from tests.gateway.devices_harness import call
from tui_gateway.contracts.registry import CANONICAL_METHODS

install = pytest.fixture(install_state)
bots = pytest_asyncio.fixture(bots_state)


def _validated(method, response):
    assert 'error' not in response, response
    CANONICAL_METHODS[method].result.model_validate(response['result'])
    return response['result']


@pytest.mark.asyncio
async def test_a_control_grant_sets_the_photo_and_every_bot_reads_the_same_one(bots):
    image = png(1)
    saved = _validated('bot_mode.about_you.set_photo', await call(
        bots.connect(), 'bot_mode.about_you.set_photo', {'data': b64(image)}))
    assert len(saved['photo_version']) == 16

    for bot in ('default', 'alpha', 'beta'):
        photo = _validated('bot_mode.about_you.photo', await call(
            bots.connect(bot, capabilities=READ), 'bot_mode.about_you.photo', {}))
        assert photo == {'data': b64(image), 'mime': 'image/png', 'photo_version': saved['photo_version']}
        facts = _validated('bot_mode.about_you.get', await call(
            bots.connect(bot, capabilities=READ), 'bot_mode.about_you.get', {}))
        assert facts['photo_version'] == saved['photo_version']


@pytest.mark.asyncio
async def test_a_read_only_grant_cannot_change_the_photo(bots):
    await call(bots.connect(), 'bot_mode.about_you.set_photo', {'data': b64(png(2))})
    before = (await call(bots.connect(capabilities=READ), 'bot_mode.about_you.photo', {}))['result']

    for data in (b64(png(3)), None):
        refused = await call(bots.connect(capabilities=READ), 'bot_mode.about_you.set_photo', {'data': data})
        assert failure(refused)['message'] == 'permission_denied'
    assert (await call(bots.connect(capabilities=READ), 'bot_mode.about_you.photo', {}))['result'] == before


@pytest.mark.asyncio
async def test_removing_the_photo_clears_it_for_everyone(bots):
    await call(bots.connect(), 'bot_mode.about_you.set_photo', {'data': b64(png(4))})

    cleared = _validated('bot_mode.about_you.set_photo', await call(
        bots.connect('alpha'), 'bot_mode.about_you.set_photo', {'data': None}))

    assert cleared['photo_version'] == ''
    photo = _validated('bot_mode.about_you.photo', await call(bots.connect('beta'), 'bot_mode.about_you.photo', {}))
    assert photo == {'data': '', 'mime': '', 'photo_version': ''}


@pytest.mark.asyncio
@pytest.mark.parametrize('params,field', [
    ({'data': 'x', 'extra': 1}, 'extra'),
    ({'data': 5}, 'data'),
])
async def test_unknown_or_mistyped_keys_are_refused_before_anything_is_stored(bots, params, field):
    error = failure(await call(bots.connect(), 'bot_mode.about_you.set_photo', params))
    assert error['data']['reason'] == 'invalid_params' and field in error['data']['fields']
    photo = await call(bots.connect(capabilities=READ), 'bot_mode.about_you.photo', {})
    assert photo['result']['photo_version'] == ''


@pytest.mark.asyncio
async def test_a_bad_image_is_refused_with_the_avatar_error_codes(bots):
    response = await call(bots.connect(), 'bot_mode.about_you.set_photo', {'data': b64(gif())})
    assert response['error']['code'] == 4070
    photo = await call(bots.connect(capabilities=READ), 'bot_mode.about_you.photo', {})
    assert photo['result']['photo_version'] == ''
