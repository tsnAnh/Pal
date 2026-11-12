"""Offline doctor findings as one JSON line, for ``host.health``.

Runs in its own process because the doctor checks print to stdout. Only checks that read local state run
here: no provider probes, no network, no secret files.
"""

from __future__ import annotations

import contextlib
import io
import json
import sys


def offline_checks():
    from hermes_cli.doctor import DOCTOR_CHECKS
    wanted = {"_check_python_environment", "_check_required_packages", "_check_directory_structure",
              "_check_state_db", "_check_cron_store", "_check_checkpoint_store", "_check_gateway_supervision",
              "_check_command_installation", "_check_profiles"}
    return [check for _, check in DOCTOR_CHECKS if getattr(check, "__name__", "") in wanted]


def collect() -> dict:
    from hermes_cli.doctor_report import Finding
    total = Finding()
    with contextlib.redirect_stdout(io.StringIO()):
        for check in offline_checks():
            total.merge(check(False))
    return {"issues": [str(i) for i in total.issues], "manual_issues": [str(i) for i in total.manual_issues]}


if __name__ == "__main__":
    sys.stdout.write(json.dumps(collect()) + "\n")
