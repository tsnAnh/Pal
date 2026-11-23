from __future__ import annotations

import argparse
import copy
import json
import logging
import secrets
import subprocess
import time
from contextlib import ExitStack
from enum import StrEnum
from pathlib import Path
from typing import Callable

from ruamel.yaml.error import YAMLError

from gateway import public_address
from gateway.webapp_listener import TOKEN_PATH, browser_session_token, dial_origin, webapp_settings
from hermes_cli.config import get_env_value, load_config, remove_env_value, save_config, save_env_value
from hermes_constants import get_hermes_home
from utils import atomic_write_text

logger = logging.getLogger(__name__)

USERNAME = "pal"
SECRET_ENV = "HERMES_DASHBOARD_BASIC_AUTH_SECRET"
SESSION_TOKEN_ENV = "HERMES_DASHBOARD_SESSION_TOKEN"
_TAILSCALE_KNOWN_DIRS = ("/Applications/Tailscale.app/Contents/MacOS",)
RECORD_PATH = Path("webapp") / "tailnet.json"
HTTPS_PORT = 443
_PASSWORD_BYTES = 18
_SECRET_BYTES = 32
_SERVE_TIMEOUT_SECONDS = 20
_QUERY_TIMEOUT_SECONDS = 10
_REACHABLE_ATTEMPTS = 8
_REACHABLE_INTERVAL_SECONDS = 2.0
_ABSENT = object()

MSG_NOT_CONFIGURED = "Pal isn't running on this Mac yet."
MSG_MISSING = "Install Tailscale on this Mac first."
MSG_NOT_RUNNING = "Tailscale isn't running on this Mac. Open Tailscale and sign in, then try again."
MSG_HTTPS = "Turn on HTTPS certificates in your Tailscale admin console, then try again."
MSG_FOREIGN = "Tailscale already serves something at this address. Turn it off first."
MSG_TAILSCALE = "Tailscale didn't respond. Try again in a moment."
MSG_RESTART = "Pal couldn't restart. Try again in a moment."
MSG_RESTART_AFTER_OFF = "Tailscale access is off, but Pal couldn't restart. Restart Pal to finish."
MSG_ADDRESS_IN_USE = "Pal already uses a different web address. Remove it first, then try again."
MSG_BUSY = "Pal is busy with a chat right now. Try again when it finishes."
MSG_FUNNEL = "Tailscale Funnel is on for this address. Turn it off first, then try again."
MSG_MANAGED = "This Mac's settings don't allow changing Pal's address."
MSG_FAILED = "Something went wrong. Try again."


class TailnetError(RuntimeError):
    pass


def _redact(text: str, password: str | None) -> str:
    return text.replace(password, "***") if password else text


def _tailscale(run: Callable[..., subprocess.CompletedProcess], *args: str,
               timeout: int = _QUERY_TIMEOUT_SECONDS) -> subprocess.CompletedProcess:
    from hermes_platform.resolver import locate_command
    command = locate_command("tailscale", known_dirs=_TAILSCALE_KNOWN_DIRS).command
    if not command:
        raise _CliMissing(MSG_MISSING)
    try:
        return run([*command, *args], capture_output=True, text=True, timeout=timeout, check=False)
    except subprocess.TimeoutExpired as exc:
        raise _Timeout(_text(exc.stderr) + _text(exc.stdout)) from exc
    except (OSError, subprocess.SubprocessError) as exc:
        logger.warning("tailscale %s could not run: %s", args[0], exc)
        raise TailnetError(MSG_TAILSCALE) from exc


class _CliMissing(TailnetError):
    pass


class _RestartBusy(TailnetError):
    pass


class _Timeout(TailnetError):
    def __init__(self, output: str):
        super().__init__(MSG_TAILSCALE)
        self.output = output


def _text(value) -> str:
    if isinstance(value, bytes):
        return value.decode("utf-8", "replace")
    return value or ""


def _read_record(home: Path) -> dict | None:
    from utils import read_json_or_empty
    record = read_json_or_empty(Path(home) / RECORD_PATH)
    if not (isinstance(record.get("url"), str) and isinstance(record.get("port"), int)):
        return None
    return {"url": record["url"], "port": record["port"],
            "added_session_token": record.get("added_session_token") is True}


def _write_record(home: Path, url: str, port: int, added_session_token: bool) -> None:
    path = Path(home) / RECORD_PATH
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    document = {"url": url, "port": port, "added_session_token": added_session_token}
    atomic_write_text(path, json.dumps(document) + "\n", mode=0o600)


def _delete_record(home: Path) -> None:
    (Path(home) / RECORD_PATH).unlink(missing_ok=True)


def _restore_record(home: Path, record: dict | None) -> None:
    if record is None:
        _delete_record(home)
    else:
        _write_record(home, record["url"], record["port"], record["added_session_token"])


def _node_url(run: Callable[..., subprocess.CompletedProcess]) -> str:
    done = _tailscale(run, "status", "--json")
    try:
        document = json.loads(done.stdout)
        state, name = document["BackendState"], str(document["Self"]["DNSName"]).rstrip(".")
    except (ValueError, KeyError, TypeError) as exc:
        raise TailnetError(MSG_NOT_RUNNING) from exc
    if done.returncode != 0 or state != "Running" or not name:
        raise TailnetError(MSG_NOT_RUNNING)
    if "CertDomains" in document and not document["CertDomains"]:
        raise TailnetError(MSG_HTTPS)
    try:
        return public_address.normalise(f"https://{name}")
    except public_address.AddressError as exc:
        logger.warning("tailscale reported an unusable node name: %s", exc.problem)
        raise TailnetError(MSG_NOT_RUNNING) from exc


def _proxy_targets(entry: dict) -> set[str]:
    handlers = entry.get("Handlers") if isinstance(entry, dict) else None
    return {str(handler.get("Proxy")) for handler in (handlers or {}).values() if isinstance(handler, dict)}


class _Serve(StrEnum):
    absent = "absent"
    ours = "ours"
    foreign = "foreign"


def _serve_document(run: Callable[..., subprocess.CompletedProcess]) -> dict:
    done = _tailscale(run, "serve", "status", "--json")
    if done.returncode != 0:
        logger.warning("tailscale serve status failed: %s", done.stderr.strip())
        raise TailnetError(MSG_TAILSCALE)
    try:
        document = json.loads(done.stdout) if done.stdout.strip() else {}
        document.get("TCP")
    except (ValueError, AttributeError) as exc:
        raise TailnetError(MSG_TAILSCALE) from exc
    return document


def _serve_state(run: Callable[..., subprocess.CompletedProcess], target: str, *, recorded: bool) -> _Serve:
    document = _serve_document(run)
    tcp, web = document.get("TCP") or {}, document.get("Web") or {}
    entries = {host: entry for host, entry in web.items() if str(host).endswith(f":{HTTPS_PORT}")}
    if str(HTTPS_PORT) not in tcp and not entries:
        return _Serve.absent
    if not (recorded and entries and all(_proxy_targets(entry) == {target} for entry in entries.values())):
        return _Serve.foreign
    funnel = document.get("AllowFunnel") or {}
    if any(funnel.get(host) for host in entries):
        raise TailnetError(MSG_FUNNEL)
    return _Serve.ours


def _https_unavailable(output: str) -> bool:
    lowered = output.lower()
    return "https" in lowered and "not enabled" in lowered or "serve is not enabled" in lowered


def _serve_on(run: Callable[..., subprocess.CompletedProcess], target: str, password: str) -> None:
    try:
        done = _tailscale(run, "serve", "--bg", f"--https={HTTPS_PORT}", target,
                          timeout=_SERVE_TIMEOUT_SECONDS)
        output, ok = f"{done.stderr}\n{done.stdout}", done.returncode == 0
    except _Timeout as exc:
        output, ok = exc.output, False
    if ok:
        return
    logger.warning("tailscale serve failed: %s", _redact(output.strip(), password))
    raise TailnetError(MSG_HTTPS if _https_unavailable(output) else MSG_TAILSCALE)


def _serve_off(run: Callable[..., subprocess.CompletedProcess]) -> None:
    done = _tailscale(run, "serve", f"--https={HTTPS_PORT}", "off", timeout=_SERVE_TIMEOUT_SECONDS)
    if done.returncode != 0:
        logger.warning("tailscale serve off failed: %s", done.stderr.strip())
        raise TailnetError(MSG_TAILSCALE)


def _write_credentials(password: str) -> Callable[[], None]:
    from hermes_cli.plugins_cmd import ensure_basic_auth_plugin_enabled_in_config
    from plugins.dashboard_auth.basic import hash_password
    password_hash = hash_password(password)
    config = load_config()
    dashboard = config.setdefault("dashboard", {})
    plugins = config.get("plugins")
    previous_basic = copy.deepcopy(dashboard["basic_auth"]) if "basic_auth" in dashboard else _ABSENT
    previous_disabled = (copy.deepcopy(plugins["disabled"])
                         if isinstance(plugins, dict) and "disabled" in plugins else _ABSENT)
    basic = dashboard.setdefault("basic_auth", {})
    basic.update({"username": USERNAME, "password_hash": password_hash, "password": ""})
    ensure_basic_auth_plugin_enabled_in_config(config)
    save_config(config)

    def restore() -> None:
        restored = load_config()
        section = restored.setdefault("dashboard", {})
        if previous_basic is _ABSENT:
            section.pop("basic_auth", None)
        else:
            section["basic_auth"] = previous_basic
        if isinstance(restored.get("plugins"), dict):
            if previous_disabled is _ABSENT:
                restored["plugins"].pop("disabled", None)
            else:
                restored["plugins"]["disabled"] = previous_disabled
        save_config(restored)
    return restore


def _ensure_signing_secret() -> Callable[[], None] | None:
    if get_env_value(SECRET_ENV):
        return None
    save_env_value(SECRET_ENV, secrets.token_urlsafe(_SECRET_BYTES))
    return lambda: remove_env_value(SECRET_ENV)


def _ensure_session_token_env(home: Path) -> tuple[bool, Callable[[], None] | None]:
    if get_env_value(SESSION_TOKEN_ENV):
        return False, None
    browser_session_token(home)
    save_env_value(SESSION_TOKEN_ENV, f"file:{Path(home) / TOKEN_PATH}")
    return True, lambda: remove_env_value(SESSION_TOKEN_ENV)


def _save_public_url(home: Path, url: str) -> None:
    try:
        public_address.save(home, url)
    except public_address.ManagedAddressError as exc:
        raise TailnetError(MSG_MANAGED) from exc
    except public_address.AddressError as exc:
        logger.warning("webapp.public_url refused: %s", exc.problem)
        raise TailnetError(MSG_FAILED) from exc


def _restart_gateway() -> bool:
    from hermes_cli.web_server_gateway import _restart_gateway_after
    outcome = _restart_gateway_after(None, what="tailnet access change", label="tailnet")
    if outcome.get("restart_busy"):
        raise _RestartBusy(MSG_BUSY)
    if not outcome.get("restart_started"):
        logger.warning("gateway restart did not start: %s", outcome.get("restart_error"))
    return bool(outcome.get("restart_started"))


def _best_effort(undo: Callable[[], None]) -> Callable[[], None]:
    def run() -> None:
        try:
            undo()
        except (OSError, ValueError, TailnetError, YAMLError):
            logger.warning("tailnet rollback step failed", exc_info=True)
    return run


def _reachable(check: Callable[[str | None], public_address.Outcome], sleep: Callable[[float], None],
               url: str) -> bool:
    for attempt in range(_REACHABLE_ATTEMPTS):
        if check(url) is public_address.Outcome.reachable:
            return True
        if attempt < _REACHABLE_ATTEMPTS - 1:
            sleep(_REACHABLE_INTERVAL_SECONDS)
    return False


def _off_state() -> dict:
    return {"enabled": False, "url": None, "username": None, "reachable": None}


def status(home: Path, *, check: Callable[[str | None], public_address.Outcome] = public_address.check) -> dict:
    record = _read_record(home)
    url = webapp_settings(home).public_url
    if record is None or url != record["url"]:
        return _off_state()
    username = (load_config().get("dashboard", {}).get("basic_auth", {}) or {}).get("username") or None
    return {"enabled": True, "url": url, "username": username,
            "reachable": check(url) is public_address.Outcome.reachable}


def enable(home: Path, *, run: Callable[..., subprocess.CompletedProcess] = subprocess.run,
           check: Callable[[str | None], public_address.Outcome] = public_address.check,
           restart: Callable[[], bool] = _restart_gateway,
           sleep: Callable[[float], None] = time.sleep) -> dict:
    settings = webapp_settings(home)
    if not settings.enabled:
        raise TailnetError(MSG_NOT_CONFIGURED)
    record = _read_record(home)
    if settings.public_url and (record is None or settings.public_url != record["url"]):
        raise TailnetError(MSG_ADDRESS_IN_USE)
    url = _node_url(run)
    target = dial_origin(settings.host, settings.port)
    serve = _serve_state(run, target, recorded=record is not None)
    if serve is _Serve.foreign:
        raise TailnetError(MSG_FOREIGN)
    password = secrets.token_urlsafe(_PASSWORD_BYTES)
    previous_url = settings.public_url
    try:
        with ExitStack() as rollback:
            rollback.callback(_best_effort(_write_credentials(password)))
            secret_undo = _ensure_signing_secret()
            if secret_undo:
                rollback.callback(_best_effort(secret_undo))
            added_token, token_undo = _ensure_session_token_env(home)
            if token_undo:
                rollback.callback(_best_effort(token_undo))
            if serve is _Serve.absent:
                rollback.callback(_best_effort(lambda: _serve_off(run)))
                _serve_on(run, target, password)
            _save_public_url(home, url)
            rollback.callback(_best_effort(lambda: public_address.save(home, previous_url)))
            _write_record(home, url, settings.port, added_token or bool(record and record["added_session_token"]))
            rollback.callback(_best_effort(lambda: _restore_record(home, record)))
            if not restart():
                raise TailnetError(MSG_RESTART)
            rollback.pop_all()
    except TailnetError:
        raise
    except Exception as exc:
        logger.error("tailnet enable failed: %s", _redact(repr(exc), password))
        raise TailnetError(MSG_FAILED) from exc
    return {"enabled": True, "url": url, "username": USERNAME, "password": password,
            "reachable": _reachable(check, sleep, url)}


def _recorded_serve_state(home: Path, run: Callable[..., subprocess.CompletedProcess], record: dict) -> _Serve:
    target = dial_origin(webapp_settings(home).host, record["port"])
    try:
        return _serve_state(run, target, recorded=True)
    except _CliMissing:
        return _Serve.absent


def disable(home: Path, *, run: Callable[..., subprocess.CompletedProcess] = subprocess.run,
            restart: Callable[[], bool] = _restart_gateway,
            sleep: Callable[[float], None] = time.sleep) -> dict:
    record = _read_record(home)
    if record is None:
        return _off_state()
    serve = _recorded_serve_state(home, run, record)
    if webapp_settings(home).public_url == record["url"]:
        _save_public_url(home, "")
    if record["added_session_token"]:
        remove_env_value(SESSION_TOKEN_ENV)
    if serve is _Serve.ours:
        _serve_off(run)
    _delete_record(home)
    try:
        started = restart()
    except _RestartBusy:
        started = False
    if not started:
        raise TailnetError(MSG_RESTART_AFTER_OFF)
    return _off_state()


def _print_human(action: str, result: dict) -> None:
    if not result["enabled"]:
        print("Tailscale access is off.")
        return
    reach = {True: "reachable", False: "not reachable yet", None: "unknown"}[result["reachable"]]
    print(f"Tailscale access is on at {result['url']} ({reach}).")
    print(f"Username: {result['username']}")
    if "password" in result:
        print(f"Password: {result['password']}  (shown once)")


def tailnet_command(args: argparse.Namespace, *, run: Callable[..., subprocess.CompletedProcess] = subprocess.run,
                    check: Callable[[str | None], public_address.Outcome] = public_address.check,
                    restart: Callable[[], bool] = _restart_gateway,
                    sleep: Callable[[float], None] = time.sleep) -> int:
    home = get_hermes_home()
    actions = {
        "status": lambda: status(home, check=check),
        "on": lambda: enable(home, run=run, check=check, restart=restart, sleep=sleep),
        "off": lambda: disable(home, run=run, restart=restart, sleep=sleep),
    }
    try:
        result = actions[args.tailnet_command]()
    except TailnetError as exc:
        print(json.dumps({"error": str(exc)}) if args.json else str(exc))
        return 1
    if args.json:
        print(json.dumps(result))
    else:
        _print_human(args.tailnet_command, result)
    return 0
