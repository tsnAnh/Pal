from __future__ import annotations

from pathlib import Path

from gateway.chat_slack.records import SlackRecords
from hermes_constants import get_default_hermes_root


class DiscordRecords(SlackRecords):
    def __init__(self, path: Path | None = None):
        super().__init__(path or get_default_hermes_root() / "chat_discord" / "records.json")
