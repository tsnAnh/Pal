from __future__ import annotations

import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Callable

import pytest

from tests.e2e.core.bots._gate import EXPECTED_VISIBLE, MISSING_HINT, SKILLS, build
from tests.e2e.core.bots._world import World, allowed, denied, marker_for, write_skill


@pytest.fixture(scope="module", params=["legacy", "shared"])
def gate(request, tmp_path_factory) -> tuple[World, dict[str, dict[str, dict]]]:
    w = World(tmp_path_factory.mktemp(f"gate-{request.param}"))
    build(w, request.param)
    rows = {bot: w.surfaces(bot, SKILLS) for bot in ("a", "b", "c")}
    return w, rows


@pytest.fixture(params=["legacy", "shared"])
def fresh(request, tmp_path) -> World:
    w = World(tmp_path)
    build(w, request.param)
    return w


def every_cell(rows: dict[str, dict[str, dict]]):
    for bot, per_skill in rows.items():
        for name, row in per_skill.items():
            yield bot, name, row, name in EXPECTED_VISIBLE[bot]


def failures(rows, check: Callable[[dict, bool, str, str], list[str]]) -> list[str]:
    out = []
    for bot, name, row, ok in every_cell(rows):
        out += [f"{bot}/{name}: {p}" for p in check(row, ok, marker_for(name), MISSING_HINT.get((bot, name), ""))]
    return out


def check_listing(row, ok, marker, hint):
    return [] if (row["listed"], row["indexed"]) == (ok, ok) else [f"listed={row['listed']} indexed={row['indexed']} want {ok}"]


def check_view(row, ok, marker, hint):
    out = []
    for key in ("view", "view_file"):
        body = row[key]
        if ok:
            if not body.get("success"):
                out.append(f"{key} denied: {str(body)[:200]}")
            continue
        if body.get("success") is not False or body.get("reason") != "connector_not_connected":
            out.append(f"{key} not denied as connector_not_connected: {str(body)[:200]}")
        if hint not in str(body.get("error", "")):
            out.append(f"{key} error does not name {hint!r}: {body.get('error')!r}")
        if marker in json.dumps(body):
            out.append(f"{key} leaked the skill body")
    return out


def check_slash(row, ok, marker, hint):
    return [] if (marker in row["slash"]) == ok else [f"slash loaded={marker in row['slash']} want {ok}"]


def check_cron(row, ok, marker, hint):
    return [] if (marker in row["cron"]) == ok else [f"cron loaded={marker in row['cron']} want {ok}"]


def test_listing_and_prompt_index_only_show_connected_skills(gate) -> None:
    _, rows = gate
    assert not failures(rows, check_listing)


def test_skill_view_and_supporting_files_are_denied_with_the_connector_named(gate) -> None:
    _, rows = gate
    assert not failures(rows, check_view)


def test_slash_invocation_is_denied_when_not_connected(gate) -> None:
    _, rows = gate
    assert not failures(rows, check_slash)


def test_cron_job_skills_are_denied_when_not_connected(gate) -> None:
    _, rows = gate
    assert not failures(rows, check_cron)


def test_path_tricks_do_not_reach_a_gated_skill(fresh: World, tmp_path_factory) -> None:
    w = fresh
    marker = marker_for("gated-mcp")
    real = (w.catalog / "skills" if (w.catalog / ".migrated").exists() else w.home_of("b") / "skills") / "gated-mcp"
    skills_dir = w.home_of("b") / "skills"
    skills_dir.mkdir(parents=True, exist_ok=True)
    link = skills_dir / "sneaky-link"
    if not link.exists():
        link.symlink_to(real, target_is_directory=True)
    outside = tmp_path_factory.mktemp("outside-catalog")
    write_skill(outside, "outside-gated", marker="MARK_OUTSIDE", connector="mcp:srv")
    escape_home = w.catalog / "skills" if (w.catalog / ".migrated").exists() else skills_dir
    escape = escape_home / "escape-link"
    if not escape.exists():
        escape.symlink_to(outside / "outside-gated", target_is_directory=True)

    attempts = w.probe("b", """
import json, os
from tools.skills_tool import skill_view, skills_list
real = os.environ["PROBE_REAL"]
tries = {
    "direct": lambda: skill_view("gated-mcp"),
    "symlink": lambda: skill_view("sneaky-link"),
    "symlink-file": lambda: skill_view("sneaky-link", file_path="SKILL.md"),
    "dotdot-name": lambda: skill_view("../gated-mcp"),
    "dotdot-skills": lambda: skill_view("../../skills/gated-mcp"),
    "abs-md": lambda: skill_view(real + "/SKILL.md"),
    "abs-dir": lambda: skill_view(real),
    "file-dotdot": lambda: skill_view("ungated", file_path="../gated-mcp/SKILL.md"),
    "file-abs": lambda: skill_view("ungated", file_path=real + "/SKILL.md"),
    "file-via-link": lambda: skill_view("ungated", file_path="../sneaky-link/SKILL.md"),
    "escape-link": lambda: skill_view("escape-link"),
    "escape-name": lambda: skill_view("outside-gated"),
}
out = {k: fn() for k, fn in tries.items()}
listed = [s["name"] for s in json.loads(skills_list()).get("skills", [])]
emit({"results": out, "listed": listed})
""", extra_env={"PROBE_REAL": str(real)})

    direct = json.loads(attempts["results"]["direct"])
    assert direct.get("success") is False and direct.get("reason") == "connector_not_connected", direct
    leaked = {k: v[:160] for k, v in attempts["results"].items() if marker in v or "MARK_OUTSIDE" in v}
    assert not leaked, f"gated skill body reachable through: {leaked}"
    assert not {"gated-mcp", "outside-gated", "sneaky-link", "escape-link"} & set(attempts["listed"])


class HostedGateway:
    def __init__(self, items: list[dict], delay: float = 0.0) -> None:
        self.items = items
        self.delay = delay
        self.closing = threading.Event()
        self.auth_headers: list[str | None] = []
        outer = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self) -> None:
                outer.auth_headers.append(self.headers.get("Authorization"))
                outer.closing.wait(outer.delay)
                body = json.dumps({"items": outer.items, "nextCursor": None}).encode()
                self.send_response(200 if self.path.startswith("/v1/connectors") else 404)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args: object) -> None:
                return

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    @property
    def url(self) -> str:
        return f"http://127.0.0.1:{self.server.server_address[1]}"

    def close(self) -> None:
        self.closing.set()
        self.server.shutdown()
        self.server.server_close()


def hosted_rows(tmp_path: Path, items: list[dict], *, with_token: bool) -> dict[str, dict]:
    w = World(tmp_path)
    w.add_bot("a", skills={"gated-hosted": {"connector": "gmail"}, "ungated": {}})
    gateway = HostedGateway(items)
    try:
        env = {"CONNECTOR_GATEWAY_URL": gateway.url}
        if with_token:
            env["TOOL_GATEWAY_USER_TOKEN"] = "tok-hosted-e2e"
        return w.surfaces("a", ["gated-hosted", "ungated"], env)
    finally:
        gateway.close()


GMAIL_CONNECTED = [{"connector": "gmail", "enabled": True, "connected": True}]


def test_hosted_connector_skill_is_available_when_the_gateway_reports_it_connected(tmp_path) -> None:
    rows = hosted_rows(tmp_path, GMAIL_CONNECTED, with_token=True)
    assert not allowed(rows["gated-hosted"], marker_for("gated-hosted"))
    assert not allowed(rows["ungated"], marker_for("ungated"))


@pytest.mark.parametrize("items", [
    [{"connector": "gmail", "enabled": True, "connected": False}],
    [{"connector": "gmail", "enabled": False, "connected": True}],
    [{"connector": "slack", "enabled": True, "connected": True}],
    [],
], ids=["not-connected", "disabled", "other-connector-only", "empty"])
def test_hosted_connector_skill_is_denied_unless_the_gateway_reports_that_slug_connected(tmp_path, items) -> None:
    rows = hosted_rows(tmp_path, items, with_token=True)
    assert not denied(rows["gated-hosted"], marker_for("gated-hosted"), "gmail")
    assert not allowed(rows["ungated"], marker_for("ungated"))


def test_hosted_connector_skill_fails_closed_without_a_nous_token(tmp_path) -> None:
    rows = hosted_rows(tmp_path, GMAIL_CONNECTED, with_token=False)
    assert not denied(rows["gated-hosted"], marker_for("gated-hosted"), "gmail")
    assert not allowed(rows["ungated"], marker_for("ungated"))


FIRST_PROMPT_PROBE = """
import time
from agent.prompt_builder import build_skills_system_prompt
started = time.monotonic()
index = build_skills_system_prompt() or ""
emit({"hosted": "gated-hosted" in index, "ungated": "ungated" in index, "seconds": time.monotonic() - started})
"""


def first_prompt(tmp_path: Path, items: list[dict], *, with_token: bool = True, delay: float = 0.0) -> dict:
    w = World(tmp_path)
    w.add_bot("a", skills={"gated-hosted": {"connector": "gmail"}, "ungated": {}})
    gateway = HostedGateway(items, delay)
    try:
        env = {"CONNECTOR_GATEWAY_URL": gateway.url}
        if with_token:
            env["TOOL_GATEWAY_USER_TOKEN"] = "tok-hosted-e2e"
        return w.probe("a", FIRST_PROMPT_PROBE, env)
    finally:
        gateway.close()


def test_the_first_prompt_after_start_lists_a_connected_hosted_skill(tmp_path) -> None:
    out = first_prompt(tmp_path, GMAIL_CONNECTED)
    assert out["hosted"] and out["ungated"], out


def test_the_first_prompt_hides_a_hosted_skill_the_gateway_reports_unconnected(tmp_path) -> None:
    out = first_prompt(tmp_path, [{"connector": "gmail", "enabled": True, "connected": False}])
    assert not out["hosted"] and out["ungated"], out


def test_the_first_prompt_does_not_wait_without_a_nous_token(tmp_path) -> None:
    out = first_prompt(tmp_path, GMAIL_CONNECTED, with_token=False, delay=3.0)
    assert not out["hosted"] and out["ungated"] and out["seconds"] < 2.0, out


def test_the_first_prompt_waits_a_bounded_time_for_a_slow_gateway(tmp_path) -> None:
    out = first_prompt(tmp_path, GMAIL_CONNECTED, delay=4.0)
    assert not out["hosted"] and out["ungated"], out
    assert 1.5 <= out["seconds"] < 3.5, out
