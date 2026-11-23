from __future__ import annotations

from pathlib import Path
from typing import Any

from gateway.chat_slack.records import SlackRecords
from hermes_constants import get_default_hermes_root


class DiscordRecords(SlackRecords):
    def __init__(self, path: Path | None = None):
        super().__init__(path or get_default_hermes_root() / "chat_discord" / "records.json")

    def apps(self) -> list[dict[str, Any]]:
        with self._lock:
            return [{**record, "bot": key.split("|", 1)[0]} for key, record in self._read()["apps"].items()]
