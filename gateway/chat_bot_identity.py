from __future__ import annotations

import logging
import sqlite3
from pathlib import Path

from gateway.chat_install_store import ChatInstallStore
from hermes_cli.profiles import read_profile_meta
from hermes_constants import profile_name_for_home

logger = logging.getLogger(__name__)


def installed_bot_name(home: Path) -> str | None:
    bot = profile_name_for_home(home)
    if bot is None:
        return None
    try:
        installed = ChatInstallStore(home).has_active_installation(bot)
    except (OSError, sqlite3.Error):
        logger.warning("chat install lookup failed for a served profile", exc_info=True)
        return None
    return (read_profile_meta(Path(home)).get("display_name") or bot) if installed else None
