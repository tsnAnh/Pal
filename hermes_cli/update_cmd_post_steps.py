from __future__ import annotations

import re
import subprocess
import time
from contextlib import suppress
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from hermes_cli._subprocess_compat import IS_WINDOWS, kill_process_tree, windows_hide_flags

DEFAULT_TIMEOUT_SECONDS = 600
MAX_TIMEOUT_SECONDS = 3600
_NAME = re.compile(r"\A[a-z0-9][a-z0-9._-]{0,63}\Z")
_OUTPUT_LINES = 5
_LINE_LIMIT = 300


@dataclass(frozen=True)
class PostUpdateStep:
    name: str
    argv: tuple[str, ...]
    timeout: int


class InvalidStep(ValueError):
    pass


def _root_updates_section(root: Path) -> dict[str, Any]:
    from hermes_cli.config import read_user_config_raw

    updates = read_user_config_raw(root / "config.yaml").get("updates")
    return updates if isinstance(updates, dict) else {}


def _parse_step(name: str, raw: Any) -> PostUpdateStep:
    if not _NAME.match(name):
        raise InvalidStep("the step name must be lowercase letters, digits, '.', '_' or '-'")
    if not isinstance(raw, dict):
        raise InvalidStep("expected a mapping with a `command` list")
    command = raw.get("command")
    if not isinstance(command, list) or not command or not all(isinstance(part, str) and part for part in command):
        raise InvalidStep("`command` must be a non-empty list of strings (an argv, never a shell line)")
    if not Path(command[0]).is_absolute():
        raise InvalidStep("`command[0]` must be an absolute path")
    timeout = raw.get("timeout", DEFAULT_TIMEOUT_SECONDS)
    if isinstance(timeout, bool) or not isinstance(timeout, int) or not 1 <= timeout <= MAX_TIMEOUT_SECONDS:
        raise InvalidStep(f"`timeout` must be a whole number of seconds from 1 to {MAX_TIMEOUT_SECONDS}")
    return PostUpdateStep(name=name, argv=tuple(command), timeout=timeout)


def declared_post_update_steps(root: Path) -> tuple[list[PostUpdateStep], list[tuple[str, str]]]:
    declared = _root_updates_section(root).get("post_update_steps")
    if not isinstance(declared, dict):
        return [], []
    steps: list[PostUpdateStep] = []
    invalid: list[tuple[str, str]] = []
    for name, raw in sorted(declared.items(), key=lambda item: str(item[0])):
        try:
            steps.append(_parse_step(str(name), raw))
        except InvalidStep as exc:
            invalid.append((str(name), str(exc)))
    return steps, invalid


def plan_post_update_steps(root: Path) -> list[dict[str, Any]]:
    steps, _ = declared_post_update_steps(root)
    return [{"name": step.name, "command": list(step.argv)} for step in steps]


def _step_env(root: Path) -> dict[str, str]:
    from agent.secret_scope import is_multiplex_active
    from tools.environments.local import build_subprocess_env

    env = build_subprocess_env(scrub_secrets=is_multiplex_active())
    env["HERMES_HOME"] = str(root)
    return env


def _tail(text: str) -> list[str]:
    from agent.redact import redact_sensitive_text

    lines = [" ".join(line.split())[:_LINE_LIMIT] for line in redact_sensitive_text(text, force=True).splitlines() if line.strip()]
    return lines[-_OUTPUT_LINES:]


def _execute(step: PostUpdateStep, root: Path) -> tuple[int, str, str]:
    popen_kwargs: dict[str, Any] = {"creationflags": windows_hide_flags()} if IS_WINDOWS else {"process_group": 0}
    proc = subprocess.Popen(
        step.argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, encoding="utf-8", errors="replace", cwd=root, env=_step_env(root), **popen_kwargs)
    try:
        stdout, stderr = proc.communicate(timeout=step.timeout)
    except BaseException as exc:
        kill_process_tree(proc)
        with suppress(subprocess.SubprocessError, OSError):
            proc.communicate(timeout=1)
        if isinstance(exc, subprocess.TimeoutExpired):
            raise TimeoutError(f"timed out after {step.timeout}s") from None
        raise
    return proc.returncode, stdout or "", stderr or ""


def _run_step(step: PostUpdateStep, root: Path) -> None:
    from hermes_cli.update_receipt import record_step

    started = time.monotonic()
    try:
        code, stdout, stderr = _execute(step, root)
    except (OSError, TimeoutError) as exc:
        reason = str(exc) if isinstance(exc, TimeoutError) else f"could not run {step.argv[0]}: {exc.strerror or exc}"
        _fail(step, reason)
        return
    if code:
        detail = _tail(stderr) or _tail(stdout)
        _fail(step, f"exited {code}" + (f": {detail[-1]}" if detail else ""))
        return
    lines = _tail(stdout)
    for line in lines:
        print(f"  ✓ {step.name}: {line}", flush=True)
    if not lines:
        print(f"  ✓ {step.name}: done in {time.monotonic() - started:.0f}s", flush=True)
    record_step(f"post_update:{step.name}", True, lines[-1] if lines else "")


def _fail(step: PostUpdateStep, reason: str) -> None:
    from hermes_cli.update_receipt import record_followup, record_step

    record_step(f"post_update:{step.name}", False, reason)
    record_followup(
        f"post_update:{step.name}", reason,
        retry="Hermes is updated; fix the cause and run `hermes update` again to retry it")


def run_post_update_steps() -> None:
    from hermes_cli.update_receipt import record_followup
    from hermes_constants import get_default_hermes_root

    root = get_default_hermes_root()
    steps, invalid = declared_post_update_steps(root)
    for name, reason in invalid:
        record_followup(
            f"post_update:{name}", f"invalid updates.post_update_steps entry: {reason}",
            retry="fix it in config.yaml and run `hermes update` again")
    if not steps:
        return
    print()
    print("→ Running post-update steps...", flush=True)
    for step in steps:
        _run_step(step, root)
