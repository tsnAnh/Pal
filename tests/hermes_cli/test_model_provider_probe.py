from __future__ import annotations

import socket
import ssl

import httpx
import openai
import pytest

from hermes_cli import model_provider_probe as probe
from hermes_cli.auth import AuthError

KEY = "fake-key-1234567890abcdef"


def _classify(exc, key=KEY):
    return probe.classify_failure(exc, provider="deepseek", model="m", base_url="", api_key=key)


def _chained(inner):
    outer = RuntimeError("provider call failed")
    outer.__cause__ = inner
    return outer


@pytest.mark.parametrize("exc, kind, retryable", [
    (TimeoutError("slow"), "timeout", True),
    (httpx.ReadTimeout("slow"), "timeout", True),
    (openai.APITimeoutError(request=httpx.Request("POST", "http://x.test")), "timeout", True),
    (ConnectionRefusedError("refused"), "network", True),
    (socket.gaierror(-2, "Name or service not known"), "network", True),
    (httpx.ConnectError("no route"), "network", True),
    (openai.APIConnectionError(request=httpx.Request("POST", "http://x.test")), "network", True),
    (ssl.SSLError("certificate verify failed"), "network", False),
])
def test_transport_failures_map_to_timeout_or_network_even_when_wrapped(exc, kind, retryable):
    for failure in (exc, _chained(exc)):
        error = _classify(failure)
        assert (error.kind, error.retryable) == (kind, retryable)
        assert error.code and error.reason


@pytest.mark.parametrize("auth_code, kind", [("missing_external_process_cli", "unsupported"), ("anything_else", "auth")])
def test_credential_resolution_errors(auth_code, kind):
    error = _classify(AuthError("could not resolve", provider="deepseek", code=auth_code))
    assert error.kind == kind and error.code == auth_code


def test_the_reason_is_one_short_scrubbed_sentence():
    noisy = RuntimeError(f"Incorrect key {KEY}\n\n   bad things " + "x" * 600)
    error = _classify(noisy)
    assert KEY not in error.reason and "\n" not in error.reason and len(error.reason) <= 300
    assert "RuntimeError" not in error.reason and "Traceback" not in error.reason


def test_the_staged_key_is_scrubbed_even_in_stripped_form():
    error = _classify(RuntimeError(f"key was  {KEY[:-2]} oops"), key=KEY[:-2] + "\n")
    assert KEY[:-2] not in error.reason


def _params(**overrides):
    base = {"provider": "deepseek", "model": "m"}
    return probe.parse_params({**base, **overrides}, base_url_editable=True)


def test_timeout_defaults_and_clamps():
    assert _params().timeout_s == 30
    assert _params(timeout_s=500).timeout_s == 60
    assert _params(timeout_s=0.5).timeout_s == 0.5


@pytest.mark.parametrize("overrides", [
    {"timeout_s": 0}, {"timeout_s": True}, {"timeout_s": "5"}, {"model": " "}, {"model": "a" * 257},
    {"provider": 3}, {"api_key": "nö"}, {"base_url": "file:///x"},
])
def test_parse_rejects_malformed_params(overrides):
    with pytest.raises(probe.InvalidProbeParams):
        _params(**overrides)


def test_an_address_needs_an_editable_provider():
    with pytest.raises(probe.InvalidProbeParams):
        probe.parse_params({"provider": "nous", "model": "m", "base_url": "https://x.test"}, base_url_editable=False)
    parsed = probe.parse_params({"provider": "deepseek", "model": "m", "base_url": "https://x.test/v1/"},
                                base_url_editable=True)
    assert parsed.base_url == "https://x.test/v1"
