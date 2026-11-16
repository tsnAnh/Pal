"""model.options capabilities carry ``efforts`` only when the route declares an explicit per-model ladder.

The key is additive: a model with no declared list serializes exactly as before, and the generic
OpenAI-compatible fallback is never reported as if it were a per-model fact.
"""

import pytest

import hermes_cli.inventory as inv
import hermes_cli.models as models_mod
import providers
from agent.reasoning_effort import OPENAI_COMPAT_WIRE_EFFORTS, codex_supported_efforts
from hermes_cli import models_reasoning_caps


@pytest.fixture(autouse=True)
def _offline_catalogs(monkeypatch):
    monkeypatch.setattr(models_mod, "model_supports_fast_mode", lambda model: False)
    monkeypatch.setattr(models_reasoning_caps, "warm_nous_reasoning_caps_async", lambda: None)
    monkeypatch.setattr(models_reasoning_caps, "warm_openrouter_reasoning_caps_async", lambda: None)
    monkeypatch.setattr(models_reasoning_caps, "nous_model_reasoning_capabilities", lambda model, **kw: None)
    monkeypatch.setattr(models_reasoning_caps, "openrouter_model_reasoning_capabilities", lambda model, **kw: None)


def _caps(slug, *models):
    rows = [{"slug": slug, "models": list(models)}]
    inv._apply_capabilities(rows)
    return rows[0]["capabilities"]


def _profile(declared):
    class Declared:
        def supported_reasoning_efforts(self, model):
            return declared(model) if callable(declared) else declared

    return Declared()


def test_codex_reports_its_own_ladder_per_model_in_source_order():
    caps = _caps("openai-codex", "gpt-5.6", "gpt-5.1")
    for model in ("gpt-5.6", "gpt-5.1"):
        assert caps[model]["efforts"] == list(codex_supported_efforts(model))
    assert caps["gpt-5.6"]["efforts"] != caps["gpt-5.1"]["efforts"]


def test_profile_declared_ladder_is_reported_lowercased_without_padding(monkeypatch):
    monkeypatch.setattr(providers, "get_provider_profile", lambda slug: _profile(("Low", "HIGH")))
    assert _caps("relay", "m")["m"]["efforts"] == ["low", "high"]


@pytest.mark.parametrize("declared", [None, (), OPENAI_COMPAT_WIRE_EFFORTS])
def test_no_explicit_list_means_the_key_is_absent_never_the_generic_fallback(monkeypatch, declared):
    monkeypatch.setattr(providers, "get_provider_profile", lambda slug: _profile(declared))
    entry = _caps("relay", "m")["m"]
    assert "efforts" not in entry
    assert entry == {"fast": False, "reasoning": True}


def test_custom_endpoint_profile_never_reports_the_generic_wire_set():
    assert "efforts" not in _caps("custom", "anything")["anything"]


def test_openrouter_catalog_list_is_reported_but_nous_catalog_is_not(monkeypatch):
    detail = {"supports_reasoning": True, "supported_efforts": ["xhigh", "high"], "mandatory": False}
    monkeypatch.setattr(models_reasoning_caps, "openrouter_model_reasoning_capabilities", lambda m, **kw: detail)
    monkeypatch.setattr(models_reasoning_caps, "nous_model_reasoning_capabilities", lambda m, **kw: detail)
    assert _caps("openrouter", "a/b")["a/b"]["efforts"] == ["xhigh", "high"]
    assert "efforts" not in _caps("nous", "a/b")["a/b"]


def test_a_model_without_reasoning_controls_reports_no_efforts(monkeypatch):
    monkeypatch.setattr(
        models_reasoning_caps, "openrouter_model_reasoning_capabilities",
        lambda m, **kw: {"supports_reasoning": False})
    entry = _caps("openrouter", "a/b")["a/b"]
    assert entry["reasoning"] is False
    assert "efforts" not in entry
