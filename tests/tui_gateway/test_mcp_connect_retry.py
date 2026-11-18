import asyncio

import pytest

from hermes_cli.shared_catalog import read_mcp_definitions, write_mcp_definitions_locked
from hermes_constants import CATALOG_MIGRATED_MARKER, get_shared_catalog_dir
from tools.connectors.mcp_oauth_redirect import APP_REDIRECT_URI
from tui_gateway import mcp_oauth_sessions as sessions
from tui_gateway import server

CLOUDFLARE = "https://mcp.cloudflare.com/mcp?codemode=false"
UPWORK = "https://mcp.upwork.com/mcp"
LOOPBACK = "http://127.0.0.1:49152/callback"
REFUSAL = 'Registration failed: 400 {"error":"invalid_redirect_uri"}'


@pytest.fixture(autouse=True)
def home(tmp_path, monkeypatch):
    root = tmp_path / "hermes_home"
    root.mkdir()
    monkeypatch.setenv("HERMES_HOME", str(root))
    marker = get_shared_catalog_dir() / CATALOG_MIGRATED_MARKER
    marker.parent.mkdir(parents=True)
    marker.write_text("")
    monkeypatch.setattr(sessions, "_sessions", {})
    return root


def rpc(method: str, **params) -> dict:
    return server._methods[f"mcp.servers.{method}"](1, params)


def add_catalog(name: str, url: str) -> dict:
    return rpc("add", name=name, config={"url": url, "transport": "http"})


def server_row(name: str) -> dict:
    return next(s for s in rpc("list")["result"]["servers"] if s["name"] == name)


@pytest.fixture
def vendor(monkeypatch):
    attempts: list[str] = []
    state = {"accepts": lambda uri: True}

    def worker(hermes_home, server_name, cfg, reconnect_live, *, flow, on_done=None, **_):
        attempts.append(flow.redirect_uri)
        try:
            if not state["accepts"](flow.redirect_uri):
                raise RuntimeError(REFUSAL)
            asyncio.run(flow.publish_authorization_url("https://as.example.com/authorize?state=s"))
            asyncio.run(flow.wait_for_callback(timeout=10))
            flow.mark_approved()
        except Exception as exc:
            flow.mark_error(str(exc))
        finally:
            flow.mark_worker_done()
            if on_done is not None:
                on_done()

    monkeypatch.setattr(sessions, "run_worker", worker)
    state["attempts"] = attempts
    yield state
    for rec in list(sessions._sessions.values()):
        rec["flow"].mark_error("test cleanup", cancelled=True)
        sessions._shutdown_listener(rec)


def start(name: str, **extra) -> dict:
    return rpc("oauth.start", name=name, client_redirect_uri=APP_REDIRECT_URI,
               fallback_redirect_uri=LOOPBACK, **extra)


def test_add_after_the_app_rolled_back_a_failed_attempt_is_not_refused():
    assert add_catalog("cloudflare", CLOUDFLARE)["result"]["ok"] is True
    assert rpc("remove", name="cloudflare")["result"]["removed"] is True

    again = add_catalog("cloudflare", CLOUDFLARE)

    assert "error" not in again, again
    row = server_row("cloudflare")
    assert row["url"] == CLOUDFLARE
    assert row["enabled"] is True


def test_a_harmless_query_string_stays_in_the_shared_definition_but_a_secret_one_does_not():
    add_catalog("cloudflare", CLOUDFLARE)
    add_catalog("keyed", "https://mcp.example.com/mcp?api_key=abc123")

    definitions = read_mcp_definitions()

    assert definitions["cloudflare"]["url"] == CLOUDFLARE
    assert "url" not in definitions["keyed"]


def test_add_repairs_a_stub_that_lost_its_url():
    write_mcp_definitions_locked({"cloudflare": {"transport": "http"}})
    assert server_row("cloudflare")["url"] is None

    repaired = add_catalog("cloudflare", CLOUDFLARE)

    assert "error" not in repaired, repaired
    assert repaired["result"]["server"]["url"] == CLOUDFLARE
    assert server_row("cloudflare")["enabled"] is True
    assert read_mcp_definitions()["cloudflare"]["url"] == CLOUDFLARE


def test_add_of_a_complete_enabled_server_still_reports_already_exists():
    add_catalog("upwork", UPWORK)
    assert add_catalog("upwork", UPWORK)["error"]["code"] == 4090


def test_oauth_start_repairs_a_stub_from_the_connector_catalog(vendor):
    write_mcp_definitions_locked({"cloudflare": {"transport": "http"}})

    started = start("cloudflare")

    assert "error" not in started, started
    assert started["result"]["session_id"]
    assert server_row("cloudflare")["url"] == CLOUDFLARE


def test_a_second_start_replaces_the_first_instead_of_failing_in_progress(vendor):
    add_catalog("upwork", UPWORK)
    first = start("upwork")["result"]
    second = start("upwork")

    assert "error" not in second, second
    assert second["result"]["session_id"] != first["session_id"]
    assert sessions.poll_flow(first["session_id"], "upwork")["status"] == "error"
    assert sessions.poll_flow(second["result"]["session_id"], "upwork")["status"] == "pending"


def test_a_loopback_only_vendor_signs_in_through_the_client_hosted_loopback(vendor):
    vendor["accepts"] = lambda uri: uri.startswith("http://127.0.0.1")
    add_catalog("upwork", UPWORK)

    result = start("upwork")["result"]

    assert (result["redirect"], result["redirect_uri"]) == ("loopback", LOOPBACK)
    assert sessions._sessions[result["session_id"]]["httpd"] is None
