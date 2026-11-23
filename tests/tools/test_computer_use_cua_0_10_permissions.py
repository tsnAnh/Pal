"""Behavior contracts for cua-driver 0.10 permission-mode integration."""

from __future__ import annotations

import asyncio
from types import SimpleNamespace
from unittest.mock import AsyncMock, MagicMock, Mock, patch

import pytest

from tools.computer_use import cua_backend_daemon, cua_backend_driver


@pytest.fixture(autouse=True)
def _reset_computer_use_state():
    from tests.computer_use_fakes import reset_backend

    reset_backend()
    yield
    reset_backend()


def test_default_config_maps_to_standard_mode():
    from tools.computer_use import tool as computer_use

    assert computer_use._cua_permission_mode() == "standard"


def test_config_mode_change_replaces_the_cached_backend():
    from tools.computer_use import tool as computer_use

    created = []

    class _Backend:
        def __init__(self, permission_mode="standard"):
            self.permission_mode = permission_mode
            self.stopped = False
            created.append(self)

        def start(self):
            pass

        def stop(self):
            self.stopped = True

    mode = "standard"
    with patch.object(computer_use, "_cua_permission_mode", side_effect=lambda: mode), patch(
        "tools.computer_use.cua_backend.CuaDriverBackend", _Backend
    ):
        standard = computer_use._get_backend("session-a")
        mode = "bounded"
        bounded = computer_use._get_backend("session-a")

    assert standard.permission_mode == "standard"
    assert standard.stopped is True
    assert bounded.permission_mode == "bounded"
    assert bounded is not standard


@pytest.mark.platforms("linux")
def test_bounded_embedded_daemon_uses_private_socket_and_two_part_ack(tmp_path):
    from tools.computer_use import cua_backend

    process = Mock()
    process.poll.return_value = None
    process.stderr = []
    process.wait.return_value = 0
    status = SimpleNamespace(returncode=0, stdout="running", stderr="")
    stopped = SimpleNamespace(returncode=0, stdout="", stderr="")

    manifest = tmp_path / "manifest.yaml"
    manifest.write_text("version: 3\n", encoding="utf-8")
    daemon = cua_backend._EmbeddedCuaDaemon("cua-driver", "bounded", capability_manifest=str(manifest))
    with patch.object(
        cua_backend_driver,
        "_resolve_mcp_invocation",
        return_value=("/opt/cua-driver", ["mcp"]),
    ), patch.object(
        # This test pins the socket/ack contract, not overlay policy. Pin the
        # policy off so the environment-dependent auto-detect (headless CI vs
        # Wayland dev box) can't add a `--help` capability-probe subprocess.run
        # call that the fixed two-entry side_effect below doesn't budget for.
        cua_backend, "_cua_no_overlay", return_value=False,
    ), patch.object(cua_backend.subprocess, "Popen", return_value=process) as popen, patch.object(
        cua_backend.subprocess, "run", side_effect=[status, stopped]
    ), patch("hermes_cli.process_identity._update_supervised_pgids") as supervise, patch(
        # A Mock pid must never reach the real owner-death supervisor or the spawn ledger.
        "hermes_cli.process_identity.register_child"
    ), patch.object(
        # stop() releases the group once it is empty; the Mock process has no real group to probe.
        cua_backend_daemon, "release_process_group_once_empty",
        side_effect=lambda pgid, **kw: supervise("unregister", [pgid]),
    ):
        daemon.start()
        command = popen.call_args.args[0]
        env = popen.call_args.kwargs["env"]
        proxy_command, proxy_args = daemon.proxy_invocation()
        daemon.stop()

    # The private daemon is an owned child: its group is handed to the owner-death supervisor at start
    # and released once stop() has stopped it.
    assert popen.call_args.kwargs["start_new_session"] is True
    assert [c.args for c in supervise.call_args_list] == [("register", [process.pid]), ("unregister", [process.pid])]
    assert command[:2] == ["/opt/cua-driver", "serve"]
    assert "--embedded" in command
    assert command[command.index("--permission-mode") + 1] == "bounded"
    assert command[command.index("--capability-manifest") + 1] == str(manifest)
    assert "--approve-capability-manifest" in command
    assert "--dangerously-bypass-approvals" not in command
    assert env["CUA_DRIVER_PERMISSION_MODE"] == "bounded"
    assert "CUA_DRIVER_DANGEROUSLY_BYPASS_APPROVALS" not in env
    assert proxy_command == "/opt/cua-driver"
    assert proxy_args == ["mcp", "--embedded", "--socket", daemon.socket_path]


def test_standard_backend_does_not_spawn_an_embedded_daemon():
    from tools.computer_use.cua_backend import CuaDriverBackend

    assert CuaDriverBackend(permission_mode="standard")._embedded_daemon is None


def test_bounded_backend_without_a_manifest_refuses_to_start():
    from tools.computer_use.cua_backend import CuaDriverBackend

    with pytest.raises(ValueError, match="capability_manifest"):
        CuaDriverBackend(permission_mode="bounded")


def test_retired_browser_grant_cannot_change_standard_runtime(tmp_path, monkeypatch):
    from tools.computer_use.cua_backend_session import _AsyncBridge, _CuaDriverSession

    (tmp_path / "config.yaml").write_text(
        "computer_use:\n  grant_existing_profile: true\n",
        encoding="utf-8",
    )
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    session = _CuaDriverSession(_AsyncBridge())
    captured = {}

    async def drive_lifecycle():
        def capture_params(**kwargs):
            captured.update(kwargs)
            return MagicMock()

        with patch(
            "tools.computer_use.cua_backend_driver.resolve_cua_driver_cmd",
            return_value="/opt/cua-driver",
        ), patch(
            "tools.computer_use.cua_backend_driver._resolve_mcp_invocation",
            return_value=("/opt/cua-driver", ["mcp"]),
        ), patch(
            "mcp.StdioServerParameters", side_effect=capture_params
        ), patch(
            "mcp.client.stdio.stdio_client"
        ) as stdio_client, patch(
            "mcp.ClientSession"
        ) as client_session:
            stdio_client.return_value.__aenter__ = AsyncMock(
                return_value=(MagicMock(), MagicMock())
            )
            stdio_client.return_value.__aexit__ = AsyncMock(return_value=None)
            live_session = MagicMock()
            live_session.initialize = AsyncMock()
            live_session.list_tools = AsyncMock(return_value=MagicMock(tools=[]))
            client_session.return_value.__aenter__ = AsyncMock(
                return_value=live_session
            )
            client_session.return_value.__aexit__ = AsyncMock(return_value=None)

            async def stop_when_ready():
                while session._shutdown_event is None:
                    await asyncio.sleep(0)
                session._shutdown_event.set()

            stop_task = asyncio.create_task(stop_when_ready())
            try:
                await session._lifecycle_coro()
            finally:
                await stop_task

    asyncio.run(drive_lifecycle())

    assert captured["command"] == "/opt/cua-driver"
    assert captured["args"] == ["mcp"]
