"""Host-level GitHub sign-in and git/gh health for the ``github.*`` RPCs.

The login is the host user's single ``gh`` login, shared by every profile on the host. ``gh`` itself runs
the device flow and keeps the token in its own store: this module only parses the one-time code and the
verification URL from gh's output and never reads, passes or logs a token or a credential file.
"""

from __future__ import annotations

import atexit
import logging
import re
import secrets
import subprocess
import threading
import time
from dataclasses import dataclass, field
from typing import Optional

logger = logging.getLogger(__name__)

HOST = "github.com"
CODE_WAIT_SECONDS = 20.0
DEVICE_CODE_EXPIRES_SECONDS = 900
DEVICE_POLL_INTERVAL_SECONDS = 5
COMMAND_TIMEOUT_SECONDS = 15.0
HTTPS_REWRITE_KEY = "url.https://github.com/.insteadOf"
HTTPS_REWRITE_FROM = "git@github.com:"

_TOKEN_VARS = ("GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN")
_CODE = re.compile(r"one-time code:\s*([A-Z0-9]{4}-[A-Z0-9]{4})")
_URL = re.compile(r"(https://github\.com/login/device)\b")
_LOGIN = re.compile(r"Logged in to github\.com account (\S+)")

SIGNED_OUT_MESSAGE = "GitHub isn't signed in on this computer. Sign in so bots can use your repositories."
UNKNOWN_HOST_MESSAGE = ("Git is set to use SSH, but this computer doesn't recognise GitHub's SSH key yet, "
                        "so git commands can stall or fail. Switch to HTTPS to fix it.")


class SigninError(Exception):
    pass


def host_env(*, browserless: bool = False) -> dict[str, str]:
    """The host user's normal terminal environment: reuses the terminal tool's builder, so the Bot Desktop's
    XDG overrides stay out, then drops any token variable so gh answers from its own store only."""
    from tools.environments.local import _make_run_env
    env = _make_run_env({})
    for name in _TOKEN_VARS:
        env.pop(name, None)
    if browserless:
        env.update(BROWSER="true", GH_BROWSER="true", GH_PROMPT_DISABLED="1")
    return env


def _run(argv: list[str]) -> Optional[tuple[int, str]]:
    try:
        done = subprocess.run(argv, capture_output=True, text=True, timeout=COMMAND_TIMEOUT_SECONDS,
                              stdin=subprocess.DEVNULL, env=host_env(), check=False)
    except (OSError, subprocess.SubprocessError):
        return None
    return done.returncode, f"{done.stdout}\n{done.stderr}"


def _login() -> tuple[bool, Optional[str]]:
    done = _run(["gh", "auth", "status", "--hostname", HOST])
    if done is None or done[0] != 0:
        return False, None
    match = _LOGIN.search(done[1])
    return True, match.group(1) if match else None


def _git_protocol() -> str:
    done = _run(["gh", "config", "get", "git_protocol", "-h", HOST])
    value = done[1].strip().lower() if done is not None and done[0] == 0 else ""
    return value if value in ("https", "ssh") else "unset"


def _ssh_host_key_known() -> bool:
    done = _run(["ssh-keygen", "-F", HOST])
    return done is not None and done[0] == 0


def status() -> dict:
    signed_in, login = _login()
    protocol = _git_protocol()
    host_key_known = _ssh_host_key_known()
    problems = []
    if not signed_in:
        problems.append({"id": "gh_signed_out", "message": SIGNED_OUT_MESSAGE, "fix": "github.signin"})
    if protocol == "ssh" and not host_key_known:
        problems.append({"id": "git_ssh_unknown_host", "message": UNKNOWN_HOST_MESSAGE,
                         "fix": "github.git_protocol.fix"})
    return {"signed_in": signed_in, "login": login, "host": HOST, "git_protocol": protocol,
            "ssh_host_key_known": host_key_known, "problems": problems}


def fix_git_protocol() -> dict:
    calls = (["git", "config", "--global", HTTPS_REWRITE_KEY, HTTPS_REWRITE_FROM],
             ["gh", "config", "set", "git_protocol", "https"],
             ["gh", "config", "set", "git_protocol", "https", "-h", HOST])
    for argv in calls:
        done = _run(argv)
        if done is None or done[0] != 0:
            raise SigninError("Could not switch git to HTTPS")
    return status()


@dataclass(eq=False)
class _Session:
    session_id: str
    proc: subprocess.Popen
    deadline: float
    user_code: str = ""
    verification_uri: str = ""
    ready: threading.Event = field(default_factory=threading.Event)
    result: Optional[dict] = None


_lock = threading.RLock()
_current: Optional[_Session] = None
_clock = time.monotonic


def _read_prompt(session: _Session) -> None:
    stream = session.proc.stdout
    try:
        for line in stream:
            if session.ready.is_set():
                continue
            code, url = _CODE.search(line), _URL.search(line)
            if code:
                session.user_code = code.group(1)
            if url:
                session.verification_uri = url.group(1)
            if session.user_code and session.verification_uri:
                session.ready.set()
    except (OSError, ValueError):
        pass
    finally:
        session.ready.set()


def _stop(session: _Session) -> None:
    if session.proc.poll() is None:
        session.proc.kill()
    try:
        session.proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        logger.warning("gh sign-in process did not exit after kill")
    if session.proc.stdout is not None:
        session.proc.stdout.close()


def _clear(session: _Session) -> None:
    global _current
    _stop(session)
    if _current is session:
        _current = None


def _start_data(session: _Session) -> dict:
    return {"session_id": session.session_id, "user_code": session.user_code,
            "verification_uri": session.verification_uri,
            "expires_in": max(1, int(session.deadline - _clock())),
            "interval": DEVICE_POLL_INTERVAL_SECONDS}


def start() -> dict:
    global _current
    with _lock:
        if _current is not None and _current.result is None and _current.proc.poll() is None \
                and _clock() < _current.deadline:
            return _start_data(_current)
        if _current is not None:
            _clear(_current)
        argv = ["gh", "auth", "login", "--hostname", HOST, "--git-protocol", "https", "--web", "--skip-ssh-key"]
        try:
            proc = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, text=True, env=host_env(browserless=True),
                                    start_new_session=True)
        except OSError as exc:
            raise SigninError("GitHub's command-line tool isn't installed on this computer") from exc
        session = _Session(secrets.token_urlsafe(12), proc, _clock() + DEVICE_CODE_EXPIRES_SECONDS)
        threading.Thread(target=_read_prompt, args=(session,), daemon=True, name="gh-signin-reader").start()
        if not session.ready.wait(CODE_WAIT_SECONDS) or not (session.user_code and session.verification_uri):
            _stop(session)
            raise SigninError("GitHub didn't give a sign-in code. Try again.")
        _current = session
        return _start_data(session)


def poll(session_id: str) -> dict:
    with _lock:
        session = _current
        if session is None or session.session_id != session_id:
            return {"state": "failed", "message": "No GitHub sign-in is in progress."}
        if session.result is not None:
            return session.result
        code = session.proc.poll()
        if code is None:
            if _clock() < session.deadline:
                return {"state": "pending"}
            _stop(session)
            session.result = {"state": "expired", "message": "The sign-in code expired. Start again."}
        elif code == 0:
            session.result = _finish(session)
        else:
            session.result = {"state": "failed", "message": "GitHub sign-in didn't complete. Try again."}
        _stop(session)
        return session.result


def _finish(session: _Session) -> dict:
    try:
        fix_git_protocol()
    except SigninError:
        return {"state": "failed", "message": "Signed in, but couldn't switch git to HTTPS. Try the fix again."}
    signed_in, login = _login()
    if not signed_in:
        return {"state": "failed", "message": "GitHub sign-in didn't complete. Try again."}
    return {"state": "signed_in", **({"login": login} if login else {})}


def cancel(session_id: str) -> dict:
    with _lock:
        if _current is not None and _current.session_id == session_id:
            _clear(_current)
    return {"ok": True}


def cancel_all() -> None:
    with _lock:
        if _current is not None:
            _clear(_current)


atexit.register(cancel_all)
