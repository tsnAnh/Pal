from __future__ import annotations

import json
import logging
import os
import re
import signal
import subprocess
import threading
import uuid
from dataclasses import dataclass, field

from agent.memory_provider import spawn_context_thread

from .contracts.host_kit import KitReport

logger = logging.getLogger(__name__)
BINARY = "faker-kit"
STATUS_TIMEOUT_SECONDS = 20.0
JOB_TIMEOUT_SECONDS = 900.0
MAX_OUTPUT_BYTES = 262144
TAIL_CHARS = 600

SUBCOMMANDS = {"status": ("host", "status"), "update": ("host", "update"), "reload": ("host", "reload"),
               "add-project": ("add-project",)}
RELOAD_TARGETS = frozenset({"routes", "gateway"})
REPO = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})/[A-Za-z0-9._-]{1,100}$")
_TOKEN_VARS = ("GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN")
_UNSUPPORTED = re.compile(r"unknown (sub)?command|invalid choice|unrecognized (arguments|option)|no such (sub)?command|"
                          r"unknown (option|flag)|unexpected argument|not (yet )?supported|usage:", re.IGNORECASE)
_UNSUPPORTED_EXIT_CODES = (2, 64)


class KitFailure(Exception):
    def __init__(self, code: str, message: str, subcommand: str | None = None, tail: str | None = None,
                 kit_code: str | None = None, next_action: str | None = None) -> None:
        super().__init__(message)
        self.code, self.message, self.subcommand, self.tail = code, message, subcommand, tail
        self.kit_code, self.next_action = kit_code, next_action

    def as_dict(self) -> dict:
        return {"code": self.code, "message": self.message, "subcommand": self.subcommand, "tail": self.tail,
                "kit_code": self.kit_code, "next_action": self.next_action}


def host_env() -> dict[str, str]:
    from tools.environments.local import _make_run_env
    env = _make_run_env({})
    for name in _TOKEN_VARS:
        env.pop(name, None)
    return env


def build_argv(subcommand: str, arg: str | None = None) -> list[str]:
    if subcommand not in SUBCOMMANDS:
        raise ValueError(f"unknown kit subcommand {subcommand!r}")
    if subcommand == "add-project":
        if not isinstance(arg, str) or not REPO.fullmatch(arg) or ".." in arg:
            raise ValueError("repo must be owner/repo")
    elif subcommand == "reload":
        if arg not in RELOAD_TARGETS:
            raise ValueError("reload target must be routes or gateway")
    elif arg is not None:
        raise ValueError(f"{subcommand} takes no argument")
    return [BINARY, *SUBCOMMANDS[subcommand], *([arg] if arg is not None else []), "--json"]


def _tail(text: str) -> str:
    from agent.redact import redact_sensitive_text
    return redact_sensitive_text(text.strip()[-TAIL_CHARS:], force=True)


def _kill(proc: subprocess.Popen) -> None:
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        proc.kill()


def _drain(stream, sink: list[bytes], overflow: threading.Event, proc: subprocess.Popen) -> None:
    kept = 0
    for chunk in iter(lambda: stream.read(4096), b""):
        room = MAX_OUTPUT_BYTES - kept
        sink.append(chunk[:room])
        kept += min(len(chunk), room)
        if len(chunk) > room and not overflow.is_set():
            overflow.set()
            _kill(proc)


def _execute(name: str, argv: list[str], timeout: float) -> tuple[int, str, str]:
    try:
        proc = subprocess.Popen(  # health: allow HX006 -- proc.wait(timeout=) below bounds it and kills the group
            argv, shell=False, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env=host_env(),
            start_new_session=True)  # detached-spawn: ok -- awaited with a group-killing timeout (_kill)
    except OSError:
        raise KitFailure("kit_unavailable", "The kit isn't installed on this computer.", name) from None
    out: list[bytes] = []
    err: list[bytes] = []
    overflow = threading.Event()
    readers = [spawn_context_thread(_drain, name="host-kit-drain", args=(s, sink, overflow, proc))
               for s, sink in ((proc.stdout, out), (proc.stderr, err))]
    for reader in readers:
        reader.start()
    try:
        proc.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        _kill(proc)
        proc.wait(timeout=5)
        raise KitFailure("timeout", "The kit took too long to answer.", name) from None
    finally:
        for reader in readers:
            reader.join(timeout=5)
    stdout, stderr = (b"".join(part).decode("utf-8", "replace") for part in (out, err))
    if overflow.is_set():
        raise KitFailure("invalid_output", "The kit's answer was too large to read.", name, _tail(stdout or stderr))
    return proc.returncode, stdout, stderr


def _text(value: object, limit: int = 500) -> str | None:
    from agent.redact import redact_sensitive_text
    if not isinstance(value, str) or not value.strip():
        return None
    return redact_sensitive_text(value.strip()[:limit], force=True)


def _body(stdout: str) -> dict | None:
    try:
        body = json.loads(stdout)
    except ValueError:
        return None
    return body if isinstance(body, dict) else None


def _next_action(body: dict) -> str | None:
    nxt = body.get("next")
    return _text(nxt.get("action")) if isinstance(nxt, dict) else None


def _report(body: dict) -> dict:
    data = body.get("data") if isinstance(body.get("data"), dict) else {}

    def pick(key: str) -> str | None:
        return _text(body.get(key) if body.get(key) is not None else data.get(key), 200)

    return {"version": pick("version"), "status": pick("status"), "message": _text(body.get("message")),
            "next_action": _next_action(body)}


def _kit_refusal(name: str, body: dict, tail: str) -> KitFailure | None:
    kit_code = _text(body.get("code"), 64)
    if body.get("ok") is not False and kit_code is None:
        return None
    message = _text(body.get("message")) or f"The kit refused `{name}`."
    code = "request_refused" if kit_code == "request_refused" else "failed"
    return KitFailure(code, message, name, None if code == "request_refused" else tail, kit_code, _next_action(body))


def run(subcommand: str, arg: str | None = None, timeout: float | None = None) -> dict:
    timeout = STATUS_TIMEOUT_SECONDS if timeout is None else timeout
    argv = build_argv(subcommand, arg)
    code, stdout, stderr = _execute(subcommand, argv, timeout)
    tail = _tail(f"{stdout}\n{stderr}")
    body = _body(stdout)
    if body is not None:
        refusal = _kit_refusal(subcommand, body, tail)
        if refusal is not None:
            raise refusal
        if code != 0:
            raise KitFailure("failed", f"The kit reported a failure while running `{subcommand}`.", subcommand, tail)
        return KitReport.model_validate(_report(body)).model_dump()
    if code != 0:
        if code in _UNSUPPORTED_EXIT_CODES or _UNSUPPORTED.search(f"{stdout}\n{stderr}"):
            raise KitFailure("kit_unsupported", f"This kit version does not support `{subcommand}` yet.", subcommand, tail)
        raise KitFailure("failed", f"The kit reported a failure while running `{subcommand}`.", subcommand, tail)
    raise KitFailure("invalid_output", f"The kit's answer to `{subcommand}` wasn't readable.", subcommand, tail)


@dataclass
class Job:
    operation: str
    subcommand: str
    arg: str | None
    job_id: str = field(default_factory=lambda: uuid.uuid4().hex)
    state: str = "running"
    report: dict | None = None
    error: dict | None = None

    def view(self) -> dict:
        return {"job_id": self.job_id, "operation": self.operation, "state": self.state,
                "report": self.report, "error": self.error}


_lock = threading.Lock()
_job: Job | None = None


def _finish(job: Job) -> None:
    try:
        report, error, state = run(job.subcommand, job.arg, JOB_TIMEOUT_SECONDS), None, "succeeded"
    except KitFailure as exc:
        report, error, state = None, exc.as_dict(), "failed"
    except Exception:
        logger.exception("host.kit job failed")
        report, state = None, "failed"
        error = KitFailure("failed", f"The kit couldn't run `{job.subcommand}`.", job.subcommand).as_dict()
    with _lock:
        job.report, job.error, job.state = report, error, state


def start(operation: str, subcommand: str, arg: str | None = None) -> dict:
    global _job
    build_argv(subcommand, arg)
    with _lock:
        if _job is not None and _job.state == "running":
            if (_job.subcommand, _job.arg) == (subcommand, arg):
                return _job.view()
            raise KitFailure("busy", f"The kit is busy with another operation ({_job.operation}).", subcommand)
        _job = job = Job(operation, subcommand, arg)
        view = job.view()
    spawn_context_thread(_finish, name="host-kit-job", args=(job,)).start()
    return view


def get(job_id: str) -> dict | None:
    with _lock:
        return _job.view() if _job is not None and _job.job_id == job_id else None


def reset() -> None:
    global _job
    with _lock:
        _job = None
