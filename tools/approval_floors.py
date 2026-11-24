"""Floors for :mod:`tools.approval`: refusals that no setting or unattended approve-mode lifts.

Hardline, ``sudo -S`` password piping and the user's own ``approvals.deny`` globs.
"""

import fnmatch
import logging
import time
import uuid
from tools import approval_context as _ctx
from utils import unlink_files_older_than
from tools.approval_detection import (
    _FALLBACK_MATCH_SUFFIX, _MALFORMED_EXEC_DESCRIPTION, _PARSER_LIMIT_DESCRIPTION, _deny_command_variants)

logger = logging.getLogger("tools.approval")


def _match_user_deny_rule(command: str) -> str | None:
    """Return the matching ``approvals.deny`` glob, or None. User-defined fnmatch
    globs that block unconditionally, like the hardline floor. Case-insensitive,
    run over the same normalized/deobfuscated variants
    the dangerous-pattern detector uses so quoting tricks (``r\\m``,
    ``git st""atus``) can't sidestep a rule."""
    try:
        deny_patterns = _ctx._get_approval_config().get("deny") or []
    except Exception:
        return None
    globs = [p.strip() for p in deny_patterns if isinstance(p, str) and p.strip()]
    if not globs:
        return None
    for command_variant in _deny_command_variants(command):
        candidate = command_variant.lower().strip()
        for pattern in globs:
            if fnmatch.fnmatchcase(candidate, pattern.lower()):
                return pattern
    return None


def _user_deny_block_result(pattern: str) -> dict:
    """Build the standard block result for an ``approvals.deny`` match."""
    return {"approved": False, "user_deny": True, "message": (
        f"BLOCKED: this command matches the user-defined deny rule "
        f"'{pattern}' (approvals.deny in config.yaml). It cannot be "
        "executed via the agent. Do NOT retry or rephrase this command; the user has explicitly forbidden it.")}


def _save_blocked_payload(command: str) -> str | None:
    """Persist a parser-limit-blocked command for the user to review. That block fires on payload
    SIZE/nesting, not the operation, so the payload is usually a legitimate script the model
    inlined. The file is NOT a way around the block: `bash <file>` runs a script the guard never
    reads, so the hint points the model at smaller commands or at the user instead. Nothing runs
    here. Returns the path, or None on any failure. Never in a hosted scope: the command is the
    tenant's, and a host path would mean nothing inside its sandbox."""
    from tools.hosted_tool_policy import host_feature_enabled
    if not host_feature_enabled("tool_host_artifacts"):
        return None
    try:
        from hermes_constants import get_hermes_home
        script_dir = get_hermes_home() / "cache" / "blocked-scripts"
        script_dir.mkdir(parents=True, exist_ok=True)
        # Opportunistic cleanup: blocked payloads older than 7 days.
        unlink_files_older_than(script_dir, "blocked-*.sh", 7 * 86400)
        path = script_dir / f"blocked-{int(time.time())}-{uuid.uuid4().hex[:8]}.sh"
        path.write_text(
            "#!/usr/bin/env bash\n"
            "# Auto-saved by Hermes: this command exceeded the inline command\n"
            "# parser limit and was blocked from direct execution. The approval\n"
            "# guard has not read it: review all of it before running it yourself.\n"
            + command + ("" if command.endswith("\n") else "\n"),
            # UTF-8 with replacement so a non-UTF-8 command cannot fail the save on a non-UTF-8 locale.
            encoding="utf-8", errors="replace",
        )
        return str(path)
    except Exception:
        logger.debug("failed to save blocked payload", exc_info=True)
        return None


_RECOVERY_PREFIX = (
    " RECOVERY: this block fires on oversized or too deeply nested inline "
    "command payloads (heredocs, giant one-liners), not on the operation itself. "
)
# Running the payload from a file would execute a script the approval guard never read.
_RECOVERY_STEPS = (
    "Split the work into smaller commands the guard can read, or ask the user to run it "
    "themselves. Do not run the payload from a file to get around this check, and do not retry inline."
)


def _hardline_block_result(description: str, command: str = "") -> dict:
    """Build the standard block result for a hardline match."""
    message = (
        f"BLOCKED (hardline): {description}. "
        "This command is on the unconditional blocklist and cannot "
        "be executed via the agent, not even in cron approve mode. If you genuinely "
        "need to run it, run it yourself in a terminal outside the agent."
    )
    # The parser-limit block is almost always a giant inline payload, not a forbidden operation, and is typically
    # followed by blind rephrase retries: say what to do instead, and save the payload for the user.
    if description in (_PARSER_LIMIT_DESCRIPTION, _MALFORMED_EXEC_DESCRIPTION) or description.endswith(_FALLBACK_MATCH_SUFFIX):
        saved = _save_blocked_payload(command) if command else None
        message += _RECOVERY_PREFIX + (f"Your command was saved to {saved} for the user to review. " if saved else "")
        message += _RECOVERY_STEPS
    return {"approved": False, "hardline": True, "message": message}


def _sudo_stdin_block_result(description: str) -> dict:
    """Build the standard block result for sudo stdin guard."""
    return {"approved": False, "message": (
        f"BLOCKED: {description}. "
        "Do not pipe passwords to 'sudo -S' — this is a brute-force "
        "attack vector. Set SUDO_PASSWORD in your .env file if the "
        "agent needs passwordless sudo, or run the sudo command manually in your own terminal.")}
