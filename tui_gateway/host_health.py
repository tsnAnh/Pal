"""Read-only host facts for ``host.health``. Every field degrades to None; nothing here raises."""

from __future__ import annotations

import json
import logging
import platform
import shutil
import subprocess
import sys
import time

logger = logging.getLogger(__name__)

DOCTOR_TIMEOUT_SECONDS = 45
MAX_PROBLEMS = 20
MAX_PROBLEM_CHARS = 300
DOCTOR_ARGV = (sys.executable, "-m", "hermes_cli.doctor_summary")


def _safely(read):
    try:
        return read()
    except Exception:
        logger.debug("host.health field unreadable", exc_info=True)
        return None


def _version() -> tuple[str | None, str | None]:
    from hermes_cli.version_info import get_version_info
    info = get_version_info()
    return info.display_version, info.commit


def _disk() -> tuple[int | None, int | None]:
    from hermes_constants import get_hermes_home
    usage = shutil.disk_usage(get_hermes_home())
    return usage.free, usage.total


def _uptime_seconds() -> int | None:
    import psutil
    return max(0, int(time.time() - psutil.boot_time()))


def _profile_counts() -> tuple[int | None, int | None]:
    from hermes_cli.profiles import list_profiles
    profiles = list_profiles(lazy_skill_count=True)
    return len(profiles), sum(1 for p in profiles if p.gateway_running)


def run_doctor() -> dict | None:
    done = subprocess.run(list(DOCTOR_ARGV), capture_output=True, text=True, timeout=DOCTOR_TIMEOUT_SECONDS,
                          stdin=subprocess.DEVNULL, check=False)
    if done.returncode != 0:
        return None
    return json.loads(done.stdout.strip().splitlines()[-1])


def _problems(report: dict) -> list[dict]:
    from tui_gateway.host_logs import redact
    rows = [("warning", m) for m in report.get("issues", [])] + [("error", m) for m in report.get("manual_issues", [])]
    return [{"severity": severity, "message": redact(" ".join(str(message).split()))[:MAX_PROBLEM_CHARS]}
            for severity, message in rows[:MAX_PROBLEMS]]


def collect() -> dict:
    version, commit = _safely(_version) or (None, None)
    free, total = _safely(_disk) or (None, None)
    count, running = _safely(_profile_counts) or (None, None)
    report = _safely(run_doctor)
    return {
        "version": version,
        "commit": commit,
        "python_version": platform.python_version(),
        "platform": _safely(lambda: f"{platform.system()} {platform.machine()}".strip()),
        "disk_free_bytes": free,
        "disk_total_bytes": total,
        "host_uptime_seconds": _safely(_uptime_seconds),
        "profile_count": count,
        "running_gateway_count": running,
        "doctor_ran": report is not None,
        "problems": _problems(report) if report is not None else [],
    }
