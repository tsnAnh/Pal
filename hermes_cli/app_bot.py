from __future__ import annotations

import dataclasses
import os
import time
from pathlib import Path

from gateway.session_context import get_session_env
from hermes_cli.bot_onboarding import mark_onboarding_pending
from hermes_cli.profile_provision import ProfileCreateRequest
from hermes_cli.profile_yaml import update_profile_yaml
from hermes_cli.profiles import get_profile_dir, normalize_profile_name

_FORM_CLONE_SOURCE = "default"
_META_KEY = "hermes-bots"
_SCRIPT_TOOL_ENV = ("HERMES_RPC_SOCKET", "HERMES_RPC_DIR")


def run_by_agent_tool() -> bool:
    return bool(get_session_env("HERMES_SESSION_ID", "")) or any(name in os.environ for name in _SCRIPT_TOOL_ENV)


def form_request(request: ProfileCreateRequest) -> ProfileCreateRequest:
    if request.clone_all:
        return request
    slug = normalize_profile_name(request.name)
    soul = "\n".join([
        f"# {slug}", "",
        f"You are {slug}, a persistent named agent (profile `{slug}`) on this machine.",
        "You keep your own memory, skills, and conversation history across sessions.",
    ])
    starts_fresh = request.no_skills or not request.mirror_credentials
    if starts_fresh or request.clone_config:
        return dataclasses.replace(request, soul=soul)
    return dataclasses.replace(request, soul=soul, clone_from=_FORM_CLONE_SOURCE, clone_config=True)


def mark_app_bot(profile_dir: Path, title: str) -> None:
    def mutate(data: dict) -> None:
        ui_meta = data.get("ui_meta") if isinstance(data.get("ui_meta"), dict) else {}
        revisions = data.get("_ui_meta_revisions") if isinstance(data.get("_ui_meta_revisions"), dict) else {}
        data["ui_meta"] = {**ui_meta, _META_KEY: {"title": title, "created": int(time.time() * 1000)}}
        data["_ui_meta_revisions"] = {**revisions, _META_KEY: revisions.get(_META_KEY, 0) + 1}

    if not update_profile_yaml(profile_dir, mutate):
        raise OSError(f"{profile_dir / 'profile.yaml'} is unreadable")


def finish_form_bot(name: str, made_path: str) -> None:
    slug = normalize_profile_name(name)
    profile_dir = get_profile_dir(slug)
    if not profile_dir.is_dir() or Path(made_path).resolve() != profile_dir.resolve():
        raise OSError("the profile was made on another machine")
    mark_app_bot(profile_dir, slug)
    mark_onboarding_pending(profile_dir)
