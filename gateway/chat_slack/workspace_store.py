from __future__ import annotations

import json
import logging
from collections.abc import Callable, Iterable
from pathlib import Path
from typing import Any

from agent.vault_store import VaultError, VaultStore
from hermes_constants import get_hermes_home

from .records import SlackRecords
from .token_store import CONFIG_ITEM_LABEL

logger = logging.getLogger(__name__)

RECORDS_RELATIVE = Path("chat_slack") / "records.json"
LegacySource = tuple[SlackRecords, VaultStore]


def profile_sources(current: tuple[SlackRecords, VaultStore] | None = None) -> list[LegacySource]:
    from hermes_cli.profiles import get_profile_dir, list_profile_names

    sources = [current] if current else []
    homes = [Path(get_hermes_home()), *(get_profile_dir(name) for name in list_profile_names())]
    seen = {source[0].path.resolve() for source in sources}
    for home in homes:
        path = (home / RECORDS_RELATIVE).resolve()
        if path in seen or not path.is_file():
            continue
        seen.add(path)
        sources.append((SlackRecords(path), VaultStore(home / "vault")))
    return sources


def _names_credential(records: SlackRecords, workspace: str) -> bool:
    try:
        return bool(records.workspace(workspace).get("config_item_id"))
    except (OSError, ValueError):
        return False


class WorkspaceRecords(SlackRecords):
    def __init__(self, path: Path, vault: VaultStore, legacy: Callable[[], Iterable[LegacySource]]):
        super().__init__(path)
        self._vault, self._legacy = vault, legacy

    def workspace(self, workspace: str) -> dict[str, Any]:
        record = super().workspace(workspace)
        if record.get("config_item_id"):
            return record
        self._adopt(workspace)
        return super().workspace(workspace)

    def _adopt(self, workspace: str) -> None:
        if not any(_names_credential(records, workspace) for records, _ in self._sources()):
            return
        adopted: tuple[SlackRecords, VaultStore, str] | None = None
        with self.edit() as data:
            if data["workspaces"].get(workspace, {}).get("config_item_id"):
                return
            for records, vault in self._sources():
                if item_id := self._claim(workspace, records, vault, data):
                    adopted = records, vault, item_id
                    break
        if adopted is not None:
            self._release(workspace, *adopted)

    def _sources(self) -> list[LegacySource]:
        return [source for source in self._legacy() if source[0].path != self._path]

    def _claim(self, workspace: str, records: SlackRecords, vault: VaultStore, data: dict[str, Any]) -> str:
        try:
            held = records.workspace(workspace)
            item_id = str(held.get("config_item_id") or "")
            raw = str(vault.resolve_secret(item_id).get("api_key") or "") if item_id else ""
        except (VaultError, OSError, ValueError):
            return ""
        if not raw:
            return ""
        shared = data["workspaces"].setdefault(workspace, {})
        for key, value in held.items():
            shared.setdefault(key, value)
        shared["config_item_id"] = self._vault.add_item("api_key", CONFIG_ITEM_LABEL, {"api_key": raw}).id
        logger.info("slack workspace %s credential adopted from a bot profile", workspace)
        return item_id

    @staticmethod
    def _release(workspace: str, records: SlackRecords, vault: VaultStore, item_id: str) -> None:
        try:
            vault.remove_item(item_id)
            records.drop_workspace(workspace)
        except (VaultError, OSError, ValueError) as exc:
            logger.warning("slack workspace %s profile copy not removed: %s", workspace, type(exc).__name__)
