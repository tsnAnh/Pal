from __future__ import annotations

import json
from urllib.parse import urlsplit

SENTINEL = "\x1e__hermes_login_wall__"

PROBE_CODE = f"""
try:
    print({SENTINEL!r} + __import__("json").dumps(js(
        "(() => ({{url: location.href, wall: [...document.querySelectorAll('input[type=password]')]"
        ".some(e => e.offsetParent !== null)}}))()")))
except Exception:
    pass
"""


def host_of(url: str) -> str:
    try:
        return (urlsplit(url).hostname or "").lower()
    except ValueError:
        return ""


def split_probe(stdout: str) -> tuple[str, str | None]:
    head, sep, tail = stdout.rpartition(SENTINEL)
    if not sep:
        return stdout, None
    try:
        probe = json.loads(tail.strip().splitlines()[0])
    except (ValueError, IndexError):
        return head.rstrip("\n"), None
    wall = isinstance(probe, dict) and probe.get("wall") is True and isinstance(probe.get("url"), str)
    return head.rstrip("\n"), (probe["url"] if wall else None)


def vault_covers(host: str) -> bool:
    from agent.vault_backends import enabled_backends
    for backend in enabled_backends():
        if backend.needs_unlock and not backend.is_unlocked():
            return True
        try:
            if any(host_of(meta.origin or "") == host for meta in backend.list_items()):
                return True
        except Exception:  # health: allow BLE001 -- vault plugins raise arbitrary errors; fail closed to the vault path
            return True
    return False


def sign_in_needed(url: str) -> str | None:
    host = host_of(url)
    if not host or vault_covers(host):
        return None
    from tools.auth_required import auth_required_result
    return auth_required_result(
        f"site:{host}", "missing", flow="manual",
        message=f"{host} wants a sign-in before the page can be read. Nothing was typed. The page is open in the "
                "browser on the bot's host: the user signs in there themselves, then you read the page again.")


def intercept(stdout: str, returncode: int) -> tuple[str, str | None]:
    clean, wall_url = split_probe(stdout or "")
    return clean, (sign_in_needed(wall_url) if wall_url and returncode == 0 else None)
