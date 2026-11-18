from __future__ import annotations

import shlex
from typing import Optional

from tools.bot_dm_wire import format_delivery_report, parse_delivery_report
from tools.bot_mode_dm import MESSAGE_MAX_CHARS, _runner_argv


def delivery_wake_text(command: str, output: str) -> Optional[str]:
    """A ``--run-delivery`` process's receipt as plain labelled lines with the reply whole up to the
    message cap, or None when the process is not a delivery runner or printed something else."""
    try:
        argv = shlex.split(command)
    except ValueError:
        return None
    if "--run-delivery" not in argv or _runner_argv(argv[argv.index("--run-delivery"):]) is None:
        return None
    payload = parse_delivery_report(output)
    return format_delivery_report(payload, MESSAGE_MAX_CHARS) if payload is not None else None
