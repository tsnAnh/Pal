import json
import logging
import os
import re
import subprocess
import sys
import threading
import time
import uuid
from collections import deque
from pathlib import Path

logger = logging.getLogger(__name__)

UPDATE_ARGV = [sys.executable, "-m", "hermes_cli.main", "update", "--yes"]
CHECK_ARGV = [sys.executable, "-m", "hermes_cli.main", "update", "--check"]
RUNNER_ARGV = [sys.executable, "-m", "tui_gateway.host_update"]
CHECK_TIMEOUT_SECONDS = 120
TAIL_LINES = 40
TAIL_LINE_CHARS = 300
PHASES = ("preparing", "downloading", "applying", "installing", "restarting", "finished")
_TOKEN_VARS = ("GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN")

_PHASE_MARKERS = (
    ("restarting", re.compile(r"restart", re.IGNORECASE)),
    ("installing", re.compile(r"post-update|dependenc|installing", re.IGNORECASE)),
    ("applying", re.compile(r"Pulling updates|Switching to source commit|Switched the running checkout", re.IGNORECASE)),
    ("downloading", re.compile(r"Fetching|Found \d+ new commit|Updates available", re.IGNORECASE)),
)
_BEHIND = re.compile(r"Update available: (\d+) commit")
_UP_TO_DATE = re.compile(r"Already up to date|Up to date with the latest release|No newer release|Holding at this build")
_RELEASE_AVAILABLE = re.compile(r"Selected release available|Update available")
_NETWORK = re.compile(r"Could not resolve host|unable to access|Network is unreachable|Connection timed out|"
                      r"Failed to connect|Temporary failure in name resolution", re.IGNORECASE)
_GITHUB_REMOTE = re.compile(r"github\.com[:/]([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+?)(?:\.git)?$")

_start_lock = threading.Lock()


def state_path() -> Path:
    from hermes_constants import get_hermes_home
    return get_hermes_home() / "host-update" / "state.json"


def update_env() -> dict[str, str]:
    from hermes_constants import get_hermes_home
    from tools.environments.local import _make_run_env
    env = _make_run_env({})
    for name in _TOKEN_VARS:
        env.pop(name, None)
    env["HERMES_HOME"] = str(get_hermes_home())
    env["PYTHONUNBUFFERED"] = "1"
    return env


def install_root() -> Path:
    from hermes_cli.update_lock import _default_install_root
    return Path(_default_install_root())


def active_runs() -> int:
    from hermes_cli.gateway_service_control import HostServiceControl
    return HostServiceControl().active_runs()


def release_notes_url(root: Path) -> str | None:
    try:
        done = subprocess.run(["git", "remote", "get-url", "origin"], cwd=root, capture_output=True, text=True,
                              timeout=10, check=False, env=update_env())
    except (OSError, subprocess.SubprocessError):
        return None
    match = _GITHUB_REMOTE.search(done.stdout.strip())
    return f"https://github.com/{match.group(1)}/releases" if match else None


def parse_check(output: str, returncode: int) -> dict:
    if returncode != 0:
        return {"status": "unknown", "commits_behind": None,
                "error": "no_network" if _NETWORK.search(output) else "check_failed"}
    behind = _BEHIND.search(output)
    if behind:
        return {"status": "update_available", "commits_behind": int(behind.group(1)), "error": None}
    if _UP_TO_DATE.search(output):
        return {"status": "up_to_date", "commits_behind": 0, "error": None}
    if _RELEASE_AVAILABLE.search(output):
        return {"status": "update_available", "commits_behind": None, "error": None}
    return {"status": "unknown", "commits_behind": None, "error": "check_failed"}


def run_check() -> dict:
    try:
        done = subprocess.run(CHECK_ARGV, capture_output=True, text=True, timeout=CHECK_TIMEOUT_SECONDS,
                              check=False, env=update_env(), cwd=install_root())
        verdict = parse_check(f"{done.stdout}\n{done.stderr}", done.returncode)
    except subprocess.TimeoutExpired:
        verdict = {"status": "unknown", "commits_behind": None, "error": "no_network"}
    except OSError:
        verdict = {"status": "unknown", "commits_behind": None, "error": "check_failed"}
    return verdict


def current_version() -> dict:
    from hermes_cli.version_info import get_version_info
    info = get_version_info()
    return {"version": info.display_version, "commit": info.commit, "dirty": bool(info.dirty)}


def blockers(*, dirty: bool, runs: int, verdict_error: str | None) -> list[str]:
    from hermes_cli.update_lock import update_in_progress
    found = []
    if runs:
        found.append("turn_running")
    if dirty:
        found.append("dirty_install")
    if update_in_progress(install_root()):
        found.append("update_running")
    if verdict_error == "no_network":
        found.append("no_network")
    return found


def check() -> dict:
    root = install_root()
    version = current_version()
    verdict = run_check()
    runs = active_runs()
    return {
        "version": version["version"], "commit": version["commit"],
        "status": verdict["status"], "commits_behind": verdict["commits_behind"], "error": verdict["error"],
        "release_notes_url": release_notes_url(root), "active_runs": runs,
        "blockers": blockers(dirty=version["dirty"], runs=runs, verdict_error=verdict["error"]),
    }


def read_state() -> dict:
    try:
        raw = json.loads(state_path().read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return raw if isinstance(raw, dict) else {}


def write_state(state: dict) -> None:
    from utils import atomic_json_write
    path = state_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    atomic_json_write(path, state)


def _runner_alive(state: dict) -> bool:
    from hermes_cli.update_lock import _pid_alive, incarnation_live
    pid = state.get("pid")
    if not isinstance(pid, int):
        return time.time() - float(state.get("started_at") or 0) < 15
    if not _pid_alive(pid):
        return False
    return incarnation_live(pid, state.get("pid_create_time")) is not False


def status() -> dict:
    state = read_state()
    if state.get("state") == "running" and not _runner_alive(state):
        state = {**state, "state": "failed", "phase": state.get("phase") or "preparing",
                 "failure": "interrupted", "finished_at": time.time()}
        write_state(state)
    return public_state(state)


def public_state(state: dict) -> dict:
    return {
        "run_id": state.get("run_id"), "state": state.get("state") or "idle", "phase": state.get("phase"),
        "started_at": state.get("started_at"), "finished_at": state.get("finished_at"),
        "from_commit": state.get("from_commit"),
        "tail": list(state.get("tail") or []), "failure": state.get("failure"),
        "left_behind": state.get("left_behind"), "version": current_version()["version"],
    }


def apply(*, confirm_turns: bool) -> dict:
    with _start_lock:
        current = status()
        if current["state"] == "running":
            return {"outcome": "already_running", "blockers": [], "update": current}
        version = current_version()
        runs = active_runs()
        found = blockers(dirty=version["dirty"], runs=runs, verdict_error=None)
        refusing = [b for b in found if b != "turn_running" or not confirm_turns]
        if refusing:
            return {"outcome": "refused", "blockers": found, "update": current}
        state = {"run_id": uuid.uuid4().hex, "state": "running", "phase": "preparing", "started_at": time.time(),
                 "from_commit": version["commit"], "tail": [], "pid": None}
        write_state(state)
        try:
            subprocess.Popen([*RUNNER_ARGV, state["run_id"]], env=update_env(), cwd=install_root(),
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                             **_detach_kwargs())
        except OSError:
            logger.exception("host update runner did not start")
            write_state({**state, "state": "failed", "failure": "not_started", "finished_at": time.time(),
                         "left_behind": "nothing"})
            return {"outcome": "failed", "blockers": found, "update": status()}
        return {"outcome": "started", "blockers": found, "update": public_state(state)}


def _detach_kwargs() -> dict:
    from hermes_cli._subprocess_compat import windows_detach_popen_kwargs
    return windows_detach_popen_kwargs()


def phase_for(line: str, current: str) -> str:
    for name, marker in _PHASE_MARKERS:
        if marker.search(line):
            return name if PHASES.index(name) > PHASES.index(current) else current
    return current


def recovery_needed(root: Path) -> bool:
    from hermes_cli._early_recovery import git_operation_in_progress, interrupted_pull_marker
    return bool(git_operation_in_progress(root)) or interrupted_pull_marker(root).exists()


def failure_for(phase: str, output: str, root: Path) -> tuple[str, str, str]:
    if recovery_needed(root):
        return "needs_recovery", "needs_recovery", "tree_needs_recovery"
    reason = "no_network" if _NETWORK.search(output) else "update_failed"
    return "failed", reason, "nothing" if phase in ("preparing", "downloading") else "old_version_running"


def run_update(run_id: str) -> int:
    from agent.redact import redact_for_egress
    from hermes_cli.update_lock import process_create_time
    root = install_root()
    state = {**read_state(), "pid": os.getpid(), "pid_create_time": process_create_time()}
    if state.get("run_id") != run_id:
        return 2
    write_state(state)
    tail: deque[str] = deque(maxlen=TAIL_LINES)
    proc = subprocess.Popen(UPDATE_ARGV, env=update_env(), cwd=root, stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace")
    output: list[str] = []
    for raw in proc.stdout:
        line = redact_for_egress(raw.rstrip())[:TAIL_LINE_CHARS]
        if not line:
            continue
        output.append(line)
        tail.append(line)
        state = {**state, "phase": phase_for(line, state["phase"]), "tail": list(tail)}
        write_state(state)
    code = proc.wait()  # health: allow HX006 -- killing a half-applied update is worse than waiting; the app bounds its own wait
    finished = {**state, "finished_at": time.time(), "tail": list(tail)}
    if code == 0:
        write_state({**finished, "state": "succeeded", "phase": "finished", "failure": None})
        return 0
    outcome, reason, left = failure_for(state["phase"], "\n".join(output), root)
    write_state({**finished, "state": outcome, "failure": reason, "left_behind": left})
    return code


if __name__ == "__main__":
    sys.exit(run_update(sys.argv[1]) if len(sys.argv) == 2 else 2)
