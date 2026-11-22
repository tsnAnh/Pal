import pytest

from tools.connectors.app_scheme import AppScheme


@pytest.mark.parametrize("raw,expected", [
    ("dev.tsnanh.hermes.bot", AppScheme.release),
    ("dev.tsnanh.hermes.bot.dev", AppScheme.development),
    (None, AppScheme.release),
    ("", AppScheme.release),
    ("javascript:alert(1)", AppScheme.release),
    ("https://evil.example", AppScheme.release),
    ("dev.tsnanh.hermes.bot.dev ", AppScheme.release),
    ("DEV.TSNANH.HERMES.BOT.DEV", AppScheme.release),
    ("dev.tsnanh.hermes.bot.dev:/x", AppScheme.release),
    (7, AppScheme.release),
    (["dev.tsnanh.hermes.bot.dev"], AppScheme.release),
])
def test_only_the_two_pal_schemes_survive_parsing(raw, expected):
    assert AppScheme.parse(raw) is expected


@pytest.mark.parametrize("uri,expected", [
    ("dev.tsnanh.hermes.bot.dev:/mcp-oauth/callback", AppScheme.development),
    ("  DEV.tsnanh.hermes.bot:/x ", AppScheme.release),
    ("https://pal.example.com/cb", None),
    ("javascript:alert(1)", None),
    ("", None),
    (None, None),
])
def test_uri_scheme_lookup_is_exact(uri, expected):
    assert AppScheme.of_uri(uri) is expected
