from __future__ import annotations

import json
import threading
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Iterator

from hermes_constants import get_hermes_home
from utils import atomic_write_text


class SlackRecords:
    def __init__(self, path: Path | None = None):
        self._path = path or Path(get_hermes_home()) / "chat_slack" / "records.json"
        self._lock = threading.RLock()

    def _read(self) -> dict[str, Any]:
        if not self._path.exists():
            return {"workspaces": {}, "apps": {}}
        return json.loads(self._path.read_text(encoding="utf-8-sig"))

    @contextmanager
    def edit(self) -> Iterator[dict[str, Any]]:
        with self._lock:
            data = self._read()
            yield data
            self._path.parent.mkdir(parents=True, exist_ok=True)
            atomic_write_text(self._path, json.dumps(data, sort_keys=True))

    def workspace(self, workspace: str) -> dict[str, Any]:
        with self._lock:
            return dict(self._read()["workspaces"].get(workspace, {}))

    def update_workspace(self, workspace: str, **changes: Any) -> None:
        with self.edit() as data:
            data["workspaces"].setdefault(workspace, {}).update(changes)

    def app(self, bot: str, workspace: str) -> dict[str, Any]:
        with self._lock:
            return dict(self._read()["apps"].get(f"{bot}|{workspace}", {}))

    def apps_for(self, bot: str) -> list[dict[str, Any]]:
        with self._lock:
            return [dict(record) for key, record in self._read()["apps"].items() if key.split("|", 1)[0] == bot]

    def update_app(self, bot: str, workspace: str, **changes: Any) -> None:
        with self.edit() as data:
            data["apps"].setdefault(f"{bot}|{workspace}", {"workspace": workspace}).update(changes)

    def drop_app(self, bot: str, workspace: str) -> None:
        with self.edit() as data:
            data["apps"].pop(f"{bot}|{workspace}", None)

    def app_by_installation(self, installation_id: str) -> tuple[str, dict[str, Any] | None]:
        with self._lock:
            for record in self._read()["apps"].values():
                if record.get("installation_id") == installation_id:
                    return str(record.get("workspace", "")), dict(record)
        return "", None
