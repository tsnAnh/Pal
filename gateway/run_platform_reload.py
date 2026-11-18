"""Control-socket ``reload-platform``: rebuild one platform's adapter for one profile in place.

A bot's channel credentials are saved to its ``.env`` by the dashboard or the app. Without this verb the
running gateway only noticed that save for a named profile with no adapter yet, never for the launch
(``default``) profile, a changed token, or a removed one, so every save ended in a full gateway restart
(minutes of drain, every client dropped). The verb tears down just that platform's adapter and builds it
again from the saved files; every other adapter and every live turn is untouched.
"""

from __future__ import annotations

import asyncio
import logging
import os
from pathlib import Path
from typing import Any, Callable, Optional

logger = logging.getLogger(__name__)

NOT_SERVED_ERROR = "home is not served by this gateway"
_RELOAD_WAIT_S = 20.0


def resolve_served_home(runner: Any, requested: Path) -> tuple[Optional[str], Optional[str]]:
    """``(profile_name, error)`` for a home a control verb names: ``(None, None)`` is the launch
    profile, a name is a served secondary, and an error means this gateway does not serve the home."""
    from hermes_constants import get_hermes_home, hermes_home_key
    req_key = hermes_home_key(requested)
    if req_key == hermes_home_key(Path(get_hermes_home())):
        return None, None
    served = (getattr(runner, "_served_profile_homes", None) or {}).items()
    name = next((str(n) for n, h in served if hermes_home_key(h) == req_key), None)
    if name is None:
        return None, NOT_SERVED_ERROR
    if name == (getattr(runner, "_primary_profile_name", None) or "default"):
        return None, None
    return name, None


def _sync_process_env(home: Path, env_keys: list[str]) -> None:
    """Bring this process's own copy of the saved keys in step with its ``.env`` (set the present ones,
    drop the removed ones): the launch profile reads its credentials from ``os.environ`` first."""
    from agent.secret_scope import load_env_file
    saved = load_env_file(home / ".env")
    for key in env_keys:
        if key in saved:
            os.environ[key] = saved[key]
        else:
            os.environ.pop(key, None)


async def _reload_launch_platform(runner: Any, home: Path, platform: Any, env_keys: list[str]) -> dict[str, Any]:
    from gateway.config import load_gateway_config
    from gateway.run import _load_profile_secret_scope, _platform_has_bot_credential, _profile_runtime_scope
    await asyncio.to_thread(_sync_process_env, home, env_keys)
    secrets = await asyncio.to_thread(_load_profile_secret_scope, home)
    with _profile_runtime_scope(home, secrets):
        platform_config = load_gateway_config().platforms.get(platform)
    runner._failed_platforms.pop(platform, None)
    old = runner.adapters.pop(platform, None)
    if old is not None:
        runner.delivery_router.adapters = runner.adapters
        await runner._bounded_adapter_teardown(old, platform)
    if platform_config is None:
        runner.config.platforms.pop(platform, None)
    else:
        runner.config.platforms[platform] = platform_config
    if platform_config is None or not platform_config.enabled or not _platform_has_bot_credential(
            platform, platform_config):
        runner._update_platform_runtime_status(
            platform.value, platform_state="disabled", error_code=None, error_message=None)
        return {"reloaded": True, "connecting": False}
    runner._failed_platforms[platform] = runner._reconnect_queue_entry(
        platform, old, platform_config, attempts=0, delay=0.0)
    runner._update_platform_runtime_status(
        platform.value, platform_state="connecting", error_code=None, error_message=None)
    runner._ensure_reconnect_watcher_running()
    return {"reloaded": True, "connecting": True}


async def _reload_served_platform(runner: Any, name: str, platform: Any) -> dict[str, Any]:
    from gateway.run import _profile_runtime_scope
    homes = runner._served_profile_homes
    home = Path(homes[name])
    retry = ((getattr(runner, "_profile_failed_platforms", None) or {}).get(name) or {}).pop(platform, None)
    if isinstance(retry, asyncio.Task) and not retry.done():
        retry.cancel()
        await asyncio.wait([retry], timeout=runner._adapter_disconnect_timeout_secs())
    old = ((getattr(runner, "_profile_adapters", None) or {}).get(name) or {}).pop(platform, None)
    if old is not None:
        with _profile_runtime_scope(home, hydrate_secrets=False):
            claims = runner._adapter_claims(platform, old)
            runner._hold_secondary_claims(name, platform, old, claims)
            await runner._bounded_adapter_teardown(old, platform, profile=name)
            runner._release_secondary_claims(name, platform, old)
    await runner._apply_profile_changes(dict(homes), [], [], [name], reason="reload-platform")
    live = platform in (runner._profile_adapters.get(name) or {})
    retrying = platform in ((getattr(runner, "_profile_failed_platforms", None) or {}).get(name) or {})
    return {"reloaded": True, "connecting": live or retrying}


async def reload_platform(runner: Any, home: Path, platform_id: str, env_keys: list[str]) -> dict[str, Any]:
    """Rebuild ``platform_id``'s adapter for the profile owning ``home``. Runs on the gateway loop under
    the profile-reconcile lock, so it never interleaves with a profile rescan."""
    from gateway.config import Platform
    try:
        platform = Platform(platform_id)
    except ValueError:
        return {"reloaded": False, "error": "unknown platform"}
    name, error = resolve_served_home(runner, home)
    if error:
        return {"reloaded": False, "error": error}
    async with runner._reconcile_lock():
        if name is None:
            return await _reload_launch_platform(runner, home, platform, env_keys)
        return await _reload_served_platform(runner, name, platform)


def reload_platform_verb(runner: Any, loop: asyncio.AbstractEventLoop) -> Callable[..., dict]:
    """Answer: ``{"reloaded", "connecting"}`` or ``{"reloaded": False, "error"}``. Runs on the socket
    executor thread and marshals onto the loop; a connect that outlasts the wait keeps running and the
    caller reads ``pending`` (the platform's status settles on its own)."""

    def _handler(params: Optional[dict] = None) -> dict:
        from hermes_constants import get_hermes_home
        params = params or {}
        home = Path(str(params.get("home") or get_hermes_home())).expanduser()
        env_keys = [str(key) for key in params.get("env_keys") or []]
        future = asyncio.run_coroutine_threadsafe(
            reload_platform(runner, home, str(params.get("platform") or ""), env_keys), loop)
        try:
            return future.result(timeout=_RELOAD_WAIT_S)
        except TimeoutError:
            return {"reloaded": True, "pending": True}
        except Exception:
            logger.warning("reload-platform failed", exc_info=True)
            return {"reloaded": False, "error": "reload failed"}

    return _handler

