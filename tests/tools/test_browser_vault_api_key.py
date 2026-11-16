"""browser_vault with an ``api_key`` item: listed by name and kind, written into the focused field of the
current page with no origin binding, counts-only result, key bytes registered with the redaction boundary."""

import json
import logging

import pytest

from agent.browser_page_backend import BrowserPageBackend
from agent.redact import clear_vault_redaction_values, redact_registered_vault_values
from agent.vault_store import VaultStore

KEY = "test-key-do-not-use"


class FakePage(BrowserPageBackend):
    name = "fakepage"

    def __init__(self):
        self.calls, self.focus, self.fail_secret = [], "ok", False

    def has_page(self, task_id):
        return True

    def evaluate(self, task_id, expression, *, secret):
        self.calls.append((expression, secret))
        if secret and self.fail_secret:
            raise RuntimeError(f"page.evaluate failed: {expression}")
        refused = {"no_focused_field": {"refused": "no_focused_field"}, "not_editable": {"refused": "not_editable"}}
        if self.focus in refused:
            return json.dumps(refused[self.focus])
        return json.dumps({"filled": 1} if secret else {"ready": True})


@pytest.fixture()
def page(tmp_path, monkeypatch):
    from unittest.mock import patch

    from agent import browser_page_registry
    from tools import browser_vault_tool

    clear_vault_redaction_values()
    monkeypatch.setattr(browser_vault_tool, "_ensure_supervisor", lambda task_id: None)
    fake = FakePage()
    browser_page_registry.register_provider(fake)
    store = VaultStore(base_dir=tmp_path / "vault")
    meta = store.add_item("api_key", "OpenAI", {"api_key": KEY})
    with patch("agent.vault_store.get_vault_store", return_value=store):
        yield fake, meta
    browser_page_registry._reset_for_tests()
    clear_vault_redaction_values()


def test_list_shows_the_item_by_name_and_kind_without_origin_identifier_or_key(page, caplog):
    from tools import browser_vault_tool

    _, meta = page
    with caplog.at_level(logging.DEBUG):
        raw = browser_vault_tool.browser_vault_list()
    entry = next(i for i in json.loads(raw)["items"] if i["handle"] == meta.id)
    assert (entry["label"], entry["kind"], entry["available"]) == ("OpenAI", "api_key", True)
    assert "identifier" not in entry and not entry.get("origin")
    assert KEY not in raw and KEY not in caplog.text


def test_fill_writes_the_focused_field_and_returns_counts_only(page, caplog):
    from tools import browser_vault_tool

    fake, meta = page
    assert KEY in "x" + KEY and redact_registered_vault_values(KEY) == KEY
    with caplog.at_level(logging.DEBUG):
        raw = browser_vault_tool.browser_vault_fill(meta.id)
    assert json.loads(raw) == {"success": True, "filled_fields": 1, "kind": "api_key"}
    assert KEY not in raw and KEY not in caplog.text
    secret_calls = [secret for expr, secret in fake.calls if KEY in expr]
    assert secret_calls == [True]
    assert KEY not in redact_registered_vault_values(f"echo {KEY} echo")


@pytest.mark.parametrize("focus,error_type", [("no_focused_field", "no_focused_field"), ("not_editable", "field_not_editable")])
def test_fill_refuses_without_an_editable_focused_field_and_never_sends_the_key(page, focus, error_type):
    from tools import browser_vault_tool

    fake, meta = page
    fake.focus = focus
    out = json.loads(browser_vault_tool.browser_vault_fill(meta.id))
    assert out["success"] is False and out["error_type"] == error_type and out["error"]
    assert not any(KEY in expr for expr, _ in fake.calls)
    assert KEY not in json.dumps(out)


def test_a_failing_page_never_echoes_the_key(page):
    from tools import browser_vault_tool

    fake, meta = page
    fake.fail_secret = True
    raw = browser_vault_tool.browser_vault_fill(meta.id)
    assert json.loads(raw)["success"] is False and KEY not in raw


def test_fill_refuses_when_no_page_is_open(page):
    from agent import browser_page_registry
    from tools import browser_vault_tool

    _, meta = page
    browser_page_registry._reset_for_tests()
    out = json.loads(browser_vault_tool.browser_vault_fill(meta.id))
    assert out["success"] is False and out["error_type"] == "no_page" and KEY not in json.dumps(out)


def test_enter_code_and_save_login_refuse_an_api_key_handle(page):
    from tools import browser_vault_tool

    fake, meta = page
    out = json.loads(browser_vault_tool.browser_vault_enter_code(meta.id))
    assert out["success"] is False and out["error_type"] == "unsupported_kind" and KEY not in json.dumps(out)
    assert fake.calls == []
