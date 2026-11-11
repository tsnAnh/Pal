"""``skills.manage`` install / installed / check / update / uninstall for the scoped profile.

Each op returns the RPC result or raises ``SkillsOpError``; the CLI's console output is captured so a
blocked or failed change answers with the reason the CLI user would have read (#63307 Part B).
"""

from __future__ import annotations

import importlib


class SkillsOpError(Exception):
    def __init__(self, code: int, message: str, data: dict):
        super().__init__(message)
        self.code, self.message, self.data = code, message, data


class _CaptureConsole:
    def __init__(self):
        self.lines = []

    def print(self, *args, **kwargs):
        self.lines.append(" ".join(str(a) for a in args))

    def tail(self) -> str:
        return "\n".join(self.lines[-12:]).strip()


def _mod(name: str):
    return importlib.import_module(name)


def _failure(code: int, fallback: str, captured: _CaptureConsole, data: dict) -> SkillsOpError:
    log = captured.tail()
    return SkillsOpError(code, log.splitlines()[-1] if log else fallback, {**data, "log": log or None})


def install(query: str) -> dict:
    captured = _CaptureConsole()
    verdict = _mod("hermes_cli.skills_hub").do_install(query, skip_confirm=True, console=captured)
    bundled = _mod("tools.skills_sync_bundled_ops").bundled_skill_for_install
    installed = verdict is True or (verdict is None and bool(bundled(query)))  # an active built-in is no failure
    if not installed:
        raise _failure(5031, "skill install failed", captured, {"installed": False, "name": query})
    return {"installed": True, "name": query}


def installed(query: str) -> dict:
    keep = ("name", "identifier", "source", "trust_level", "install_path")
    rows = _mod("tools.skills_hub").HubLockFile().list_installed()
    return {"installed_skills": [{k: row.get(k) for k in keep} for row in rows]}


def check(query: str) -> dict:
    rows = _mod("tools.skills_hub_install").check_for_skill_updates(name=query or None)
    return {"updates": [{k: row.get(k) for k in ("name", "identifier", "source", "status")} for row in rows]}


def update(query: str) -> dict:
    captured = _CaptureConsole()
    if _mod("hermes_cli.skills_hub").do_update(query or None, console=captured) is False:
        raise _failure(5032, "skill update failed", captured, {"updated": False, "name": query or None})
    return {"updated": True, "name": query or None}


def uninstall(query: str) -> dict:
    if not query:
        raise SkillsOpError(4003, "name is required", {"removed": False, "name": None})
    captured = _CaptureConsole()
    if _mod("hermes_cli.skills_hub").do_uninstall(query, console=captured, skip_confirm=True) is not True:
        raise _failure(5033, "skill uninstall failed", captured, {"removed": False, "name": query})
    return {"removed": True, "name": query}


def set_key(query: str, key_name: str, value: str) -> dict:
    """Save ``value`` as ``key_name`` in the scoped profile's secret store, only when the skill ``query``
    declares ``key_name`` as a required environment variable. The value is never echoed or logged."""
    from gateway.auth_flows import credential_text

    skills = _mod("tools.skills_tool")
    match = next((s for s in skills._scanned_skill_catalog(skip_disabled=True, include_hidden=True)
                  if s["name"] == query), None)
    if match is None:
        raise SkillsOpError(4004, "skill not found", {"saved": False, "name": query})
    frontmatter, _ = _mod("agent.skill_utils").parse_frontmatter(match["path"].read_text(encoding="utf-8"))
    declared = {e["name"] for e in _mod("tools.skills_tool_setup")._get_required_environment_variables(frontmatter)}
    text = credential_text(value) if value else None
    if key_name not in declared or text is None:
        raise SkillsOpError(4101, "That key cannot be set here", {"saved": False, "name": query})
    try:
        _mod("hermes_cli.config").save_env_value_secure(key_name, text)
    except (OSError, ValueError, RuntimeError, KeyError) as exc:
        raise SkillsOpError(5034, "Could not save the key", {"saved": False, "name": query}) from exc
    return {"saved": True, "name": query}
