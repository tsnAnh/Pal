import json
import stat

import pytest

import tools.browser_use_cli as bu_cli
from tools import browser_session as bs
from tools.auth_required import AuthNeed, detect
from tools.browser_use_login_wall import SENTINEL


@pytest.fixture(autouse=True)
def _local_browser(monkeypatch):
    monkeypatch.setattr(bs, "get_session_info", lambda key: {
        "cdp_url": f"ws://127.0.0.1:47000/devtools/browser/{key}", "features": {"local": True}})
    from tools import browser_supervisor

    class _Registry:
        def get_or_start(self, *a, **kw):
            pass

        def get(self, task_id):
            return None

    monkeypatch.setattr(browser_supervisor, "SUPERVISOR_REGISTRY", _Registry())
    monkeypatch.setattr("tools.browser_use_login_wall.vault_covers", lambda host: False)


def _cli(tmp_path, monkeypatch, stdout):
    script = tmp_path / "browser-use"
    script.write_text(f"#!/bin/sh\ncat >/dev/null\nprintf '%s' '{stdout}'\n", encoding="utf-8")
    script.chmod(script.stat().st_mode | stat.S_IXUSR)
    monkeypatch.setattr(bu_cli, "_find_cli", lambda: [str(script)])


def _probe_line(url, wall):
    return f"\n{SENTINEL}{json.dumps({'url': url, 'wall': wall})}\n"


def test_login_wall_returns_typed_sign_in_needed(tmp_path, monkeypatch):
    _cli(tmp_path, monkeypatch, "page text" + _probe_line("https://app.example.com/login", True))
    result = bu_cli.browser_exec("goto_url('https://app.example.com/login')")
    need = detect("browser_exec", {}, result)
    assert need == AuthNeed("site:app.example.com", "missing", "manual")
    assert "password" not in result.lower().replace("sign-in", "")
    assert SENTINEL not in result


def test_page_without_login_wall_passes_through_and_hides_probe(tmp_path, monkeypatch):
    _cli(tmp_path, monkeypatch, "page text" + _probe_line("https://app.example.com/", False))
    result = bu_cli.browser_exec("print(1)")
    body = json.loads(result)
    assert body["success"] is True
    assert body["output"] == "page text"
    assert detect("browser_exec", {}, result) is None


def test_saved_vault_login_for_the_site_keeps_the_vault_path(tmp_path, monkeypatch):
    monkeypatch.setattr("tools.browser_use_login_wall.vault_covers", lambda host: host == "app.example.com")
    _cli(tmp_path, monkeypatch, "x" + _probe_line("https://app.example.com/login", True))
    result = bu_cli.browser_exec("print(1)")
    assert json.loads(result)["success"] is True
    assert detect("browser_exec", {}, result) is None
