"""Terminal child envs route GUI launches to the running Bot Desktop (#125830)."""

import pytest

from tools.environments.local import _make_run_env


def _publish(monkeypatch, value):
    monkeypatch.setattr("tools.bot_desktop.runtime.published_env", lambda: value)


def test_running_bot_desktop_display_rides_along(monkeypatch):
    _publish(
        monkeypatch,
        {
            "DISPLAY": ":20",
            "XAUTHORITY": "/run/hermes/bot-desktop/xauth",
            "DBUS_SESSION_BUS_ADDRESS": "unix:path=/run/hermes/bot-desktop/bus",
        },
    )
    monkeypatch.setenv("DISPLAY", ":0")
    monkeypatch.setenv("WAYLAND_DISPLAY", "wayland-0")
    env = _make_run_env({})
    assert env["DISPLAY"] == ":20"
    assert env["XAUTHORITY"] == "/run/hermes/bot-desktop/xauth"
    assert env["DBUS_SESSION_BUS_ADDRESS"] == "unix:path=/run/hermes/bot-desktop/bus"
    # X11 desktop: a leaked Wayland socket flips GTK/Chromium backends
    assert "WAYLAND_DISPLAY" not in env


def test_running_bot_desktop_beats_the_session_snapshot(monkeypatch):
    _publish(monkeypatch, {"DISPLAY": ":20"})
    monkeypatch.setenv("DISPLAY", ":0")
    env = _make_run_env({"DISPLAY": ":0"})  # login snapshot captured the seat display
    assert env["DISPLAY"] == ":20"


def test_stopped_bot_desktop_leaves_the_seat_env_alone(monkeypatch):
    _publish(monkeypatch, {})
    monkeypatch.setenv("DISPLAY", ":0")
    env = _make_run_env({})
    assert env["DISPLAY"] == ":0"
    assert "XAUTHORITY" not in env or env.get("XAUTHORITY") == ""


def test_routing_does_not_stamp_bot_desktop_activity(monkeypatch):
    stamps = []
    _publish(monkeypatch, {"DISPLAY": ":20"})
    monkeypatch.setattr(
        "tools.bot_desktop.runtime.touch_activity", lambda: stamps.append(1)
    )
    _make_run_env({})
    # A plain terminal command is not screen use; idle_stop_minutes must stay effective.
    assert stamps == []


_SCREEN = {
    "DISPLAY": ":20",
    "XAUTHORITY": "/p/bot-desktop/Xauthority",
    "DBUS_SESSION_BUS_ADDRESS": "unix:path=/p/bus",
    "XDG_CONFIG_HOME": "/p/bot-desktop/xdg",
    "XDG_CACHE_HOME": "/p/bot-desktop/xdg/.cache",
    "XDG_DATA_HOME": "/p/bot-desktop/xdg/.local-share",
}
_XDG = ("XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME")


def _host_xdg(monkeypatch):
    monkeypatch.setenv("XDG_CONFIG_HOME", "/host/config")
    monkeypatch.setenv("XDG_CACHE_HOME", "/host/cache")
    monkeypatch.delenv("XDG_DATA_HOME", raising=False)
    monkeypatch.delenv("XDG_STATE_HOME", raising=False)


def _assert_host_xdg(env):
    assert env["XDG_CONFIG_HOME"] == "/host/config"
    assert env["XDG_CACHE_HOME"] == "/host/cache"
    assert "XDG_DATA_HOME" not in env and "XDG_STATE_HOME" not in env
    assert not any("bot-desktop/xdg" in v for v in env.values())


def test_terminal_keeps_host_xdg_while_screen_runs(monkeypatch):
    _publish(monkeypatch, dict(_SCREEN))
    _host_xdg(monkeypatch)
    env = _make_run_env({})
    _assert_host_xdg(env)
    assert env["DISPLAY"] == ":20"


def test_background_process_keeps_host_xdg_while_screen_runs(monkeypatch):
    from tools.process_registry import ProcessRegistry

    _publish(monkeypatch, dict(_SCREEN))
    _host_xdg(monkeypatch)
    _assert_host_xdg(ProcessRegistry._spawn_env({}))


def test_no_screen_leaves_terminal_xdg_alone(monkeypatch):
    _publish(monkeypatch, {})
    _host_xdg(monkeypatch)
    _assert_host_xdg(_make_run_env({}))


def test_display_launch_helper_still_gets_redirected_xdg(monkeypatch):
    from tools.bot_desktop import runtime

    monkeypatch.setattr(runtime, "published_env", lambda: dict(_SCREEN))
    monkeypatch.setattr(runtime, "touch_activity", lambda: None)
    _host_xdg(monkeypatch)
    env = runtime.desktop_env()
    for key in ("XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME"):
        assert env[key] == _SCREEN[key]
