from __future__ import annotations

import contextlib
import io
import json
import logging
import sqlite3
import subprocess
import sys
from pathlib import Path
from typing import NoReturn

from hermes_cli._startup_fast import project_root_str
from hermes_cli.profile_admin_guard import ProfileAdminDenied
from tools.environments.local import build_subprocess_env

logger = logging.getLogger(__name__)

_CATALOG_TIMEOUT_SECONDS = 60
_CATALOG_SCRIPT = (
    "import json\n"
    "from tools.skills_tool import _skill_catalog\n"
    "from hermes_cli.plugins import discover_plugins, get_plugin_manager\n"
    "names = {skill['load_name'] for skill in _skill_catalog(skip_disabled=True, include_hidden=True) "
    "if skill['load_name']}\n"
    "discover_plugins()\n"
    "names |= {skill['name'] for skill in get_plugin_manager().list_plugin_skill_metadata()}\n"
    "print(json.dumps(sorted(names)))\n"
)
_MAX_DISPLAY_NAME = 64


class BotCreateError(RuntimeError):
    pass


def _die(message: str) -> NoReturn:
    print(f"Error: {message}", file=sys.stderr)
    sys.exit(1)


def _visible_skill_names(profile_dir: Path) -> list[str]:
    project_root = Path(project_root_str())
    try:
        result = subprocess.run(
            [sys.executable, "-c", _CATALOG_SCRIPT],
            env=build_subprocess_env(
                scrub_secrets=False, inherit_profile_home=False, extra={"HERMES_HOME": str(profile_dir)}),
            cwd=str(project_root), capture_output=True, text=True, encoding="utf-8", errors="replace",
            timeout=_CATALOG_TIMEOUT_SECONDS, check=False,
        )
    except subprocess.TimeoutExpired as exc:
        raise BotCreateError("could not list the skill catalog (timed out)") from exc
    lines = result.stdout.strip().splitlines()
    if result.returncode != 0 or not lines:
        raise BotCreateError(f"could not list the skill catalog: {result.stderr.strip()[-200:] or 'no output'}")
    try:
        names = json.loads(lines[-1])
    except json.JSONDecodeError as exc:
        raise BotCreateError("could not read the skill catalog") from exc
    if not isinstance(names, list) or not all(isinstance(n, str) for n in names):
        raise BotCreateError("could not read the skill catalog")
    return names


def _disable_all_skills(profile_dir: Path) -> int:
    from hermes_cli.config import atomic_config_write, read_user_config_raw

    names = _visible_skill_names(profile_dir)
    path = profile_dir / "config.yaml"
    config = read_user_config_raw(path)
    skills = config.get("skills") if isinstance(config.get("skills"), dict) else {}
    config["skills"] = {**skills, "disabled": names}
    atomic_config_write(path, config)
    return len(names)


def _discard_profile(name: str) -> None:
    from hermes_cli.profiles import delete_profile

    try:
        with contextlib.redirect_stdout(io.StringIO()):
            delete_profile(name, yes=True)
    except Exception:
        logger.warning("could not remove the half-created bot %s", name, exc_info=True)
        print(f"Warning: could not remove the half-created profile '{name}'; run `hermes profile delete {name}`.",
              file=sys.stderr)


def _creating_session_route() -> dict[str, str]:
    from gateway.session_context import get_session_env
    from hermes_state import SessionDB

    session_id = get_session_env("HERMES_SESSION_ID", "").strip()
    if not session_id:
        return {}
    try:
        db = SessionDB(read_only=True)
        try:
            row = db.get_session(session_id) or {}
        finally:
            db.close()
    except sqlite3.Error:
        logger.warning("could not read the creating session's model; the bot keeps the profile's model",
                       exc_info=True)
        return {}
    try:
        config = json.loads(row.get("model_config") or "{}")
    except (TypeError, json.JSONDecodeError):
        return {}
    if not isinstance(config, dict):
        return {}
    runtime = config.get("gateway_runtime")
    if isinstance(runtime, dict) and runtime.get("provider"):
        route, model = runtime, row.get("model")
    else:
        route, model = config, config.get("model")
    model, provider = str(model or "").strip(), str(route.get("provider") or "").strip()
    if not (model and provider):
        return {}
    block = {"default": model, "provider": provider}
    for key in ("base_url", "api_mode"):
        if isinstance(route.get(key), str) and route[key].strip():
            block[key] = route[key].strip()
    return block


def _pin_creating_session_model(profile_dir: Path) -> None:
    from hermes_cli.config import atomic_config_replace, read_user_config_raw
    from hermes_cli.profile_model_seed import launch_model_seed, merge_endpoint_seed
    from hermes_constants import get_hermes_home

    route = _creating_session_route()
    if not route:
        return
    source = read_user_config_raw(get_hermes_home() / "config.yaml")
    current = source.get("model") if isinstance(source.get("model"), dict) else {}
    same_endpoint = (current.get("provider"), current.get("base_url")) == (route["provider"], route.get("base_url"))
    carried = {key: value for key, value in current.items()
               if key != "context_length" or current.get("default") == route["default"]} if same_endpoint else {}
    seed = launch_model_seed({**source, "model": {**carried, **route}})
    path = profile_dir / "config.yaml"
    config = merge_endpoint_seed(read_user_config_raw(path), seed)
    config["model"] = seed["model"]
    atomic_config_replace(path, config)


def create_bot(name: str, *, display_name: str | None = None, description: str | None = None) -> tuple[str, Path]:
    from hermes_cli.bot_onboarding import mark_onboarding_pending
    from hermes_cli.profiles import create_profile, set_profile_display_name

    cleaned_display = (display_name or "").strip()
    if len(cleaned_display) > _MAX_DISPLAY_NAME:
        raise BotCreateError(f"Display name too long ({len(cleaned_display)} chars, max {_MAX_DISPLAY_NAME}).")
    try:
        profile_dir = create_profile(name, no_alias=True, no_skills=True, description=description)
    except (ValueError, FileExistsError) as exc:
        raise BotCreateError(str(exc)) from exc
    canon = profile_dir.name
    try:
        if cleaned_display:
            set_profile_display_name(canon, cleaned_display)
        _pin_creating_session_model(profile_dir)
        _disable_all_skills(profile_dir)
        mark_onboarding_pending(profile_dir)
    except BaseException:
        _discard_profile(canon)
        raise
    return canon, profile_dir


def _bot_create(args) -> None:
    try:
        canon, profile_dir = create_bot(
            args.bot_name, display_name=getattr(args, "display_name", None),
            description=getattr(args, "description", None),
        )
    except (BotCreateError, ValueError, ProfileAdminDenied) as exc:
        _die(str(exc))
    if getattr(args, "json", False):
        print(json.dumps({"name": canon, "home": str(profile_dir)}))
    else:
        print(f"created bot {canon}")


BOT_ACTIONS = {"create": _bot_create}


def cmd_bot(args) -> None:
    handler = BOT_ACTIONS.get(getattr(args, "bot_action", None))
    if handler is None:
        _die("usage: hermes bot create <name> [--display-name X] [--description X] [--json]")
    handler(args)
