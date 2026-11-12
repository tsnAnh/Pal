import pytest

from hermes_cli.dashboard_auth.routes import _validate_loopback_redirect_uri

PAL_APP_REDIRECTS = (
    "http://127.0.0.1:49152/callback",
    "http://127.0.0.1:65535/callback",
    "http://127.0.0.1:1/callback",
)


@pytest.mark.parametrize("redirect_uri", PAL_APP_REDIRECTS)
def test_gateway_accepts_the_redirect_forms_the_pal_apps_send(redirect_uri):
    assert _validate_loopback_redirect_uri(redirect_uri) == redirect_uri
