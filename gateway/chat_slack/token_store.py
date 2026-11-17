from __future__ import annotations

import json
import logging
import threading
import time
from dataclasses import asdict, dataclass
from typing import Callable

from agent.vault_store import VaultError, VaultStore
from tui_gateway.contracts.chat_provider import SetupErrorCode

from .api import SlackApi, SlackSetupError
from .records import SlackRecords

logger = logging.getLogger(__name__)

ROTATE_MARGIN_S = 30 * 60
WRITE_ATTEMPTS = 3
REFRESH_TOKEN_PREFIX = "xoxe-"
ACCESS_LIFETIME_S = 12 * 60 * 60


@dataclass(frozen=True)
class TokenPair:
    access_token: str
    refresh_token: str
    expires_at: float


class ConfigTokenStore:
    def __init__(self, vault: VaultStore, api: SlackApi, records: SlackRecords, *,
                 clock: Callable[[], float] = time.time):
        self._vault, self._api, self._records, self._clock = vault, api, records, clock
        self._locks: dict[str, threading.Lock] = {}
        self._locks_guard = threading.Lock()
        self._unwritten: dict[str, TokenPair] = {}

    def bind(self, workspace: str, vault_item_id: str) -> None:
        self._records.update_workspace(workspace, config_item_id=vault_item_id)

    def adopt_pair(self, workspace: str, item_id: str, access_token: str, refresh_token: str | None) -> None:
        pair = TokenPair(access_token, refresh_token or "", 0.0 if refresh_token else self._clock() + ACCESS_LIFETIME_S)
        with self._lock(workspace):
            self._write(workspace, item_id, pair)
        self.bind(workspace, item_id)

    def valid_config_token(self, workspace: str) -> str:
        return self._token(workspace, force=False)

    def rotate(self, workspace: str) -> str:
        return self._token(workspace, force=True)

    def _lock(self, workspace: str) -> threading.Lock:
        with self._locks_guard:
            return self._locks.setdefault(workspace, threading.Lock())

    def _token(self, workspace: str, *, force: bool) -> str:
        with self._lock(workspace):
            item_id = self._item_id(workspace)
            pair = self._unwritten.get(workspace)
            if pair is not None:
                self._write(workspace, item_id, pair)
            else:
                pair = self._load(item_id)
            if not force and pair.access_token and pair.expires_at - self._clock() > ROTATE_MARGIN_S:
                return pair.access_token
            return self._rotate(workspace, item_id, pair)

    def _item_id(self, workspace: str) -> str:
        item_id = self._records.workspace(workspace).get("config_item_id")
        if not item_id:
            raise SlackSetupError(SetupErrorCode.credential_rejected)
        return item_id

    def _load(self, item_id: str) -> TokenPair:
        try:
            value = str(self._vault.resolve_secret(item_id).get("api_key") or "")
        except VaultError:
            raise SlackSetupError(SetupErrorCode.credential_rejected) from None
        if value.startswith(REFRESH_TOKEN_PREFIX):
            return TokenPair("", value, 0.0)
        try:
            return TokenPair(**json.loads(value))
        except (ValueError, TypeError):
            raise SlackSetupError(SetupErrorCode.credential_rejected) from None

    def _rotate(self, workspace: str, item_id: str, pair: TokenPair) -> str:
        if not pair.refresh_token:
            raise SlackSetupError(SetupErrorCode.credential_expired)
        body = self._api.call("tooling.tokens.rotate", data={"refresh_token": pair.refresh_token})
        fresh = TokenPair(str(body["token"]), str(body["refresh_token"]), float(body["exp"]))
        self._unwritten[workspace] = fresh
        self._write(workspace, item_id, fresh)
        logger.info("slack config token rotated for workspace %s", workspace)
        return fresh.access_token

    def _write(self, workspace: str, item_id: str, pair: TokenPair) -> None:
        for _ in range(WRITE_ATTEMPTS):
            try:
                self._vault.update_item(item_id, secret={"api_key": json.dumps(asdict(pair))})
            except (VaultError, OSError):
                continue
            self._unwritten.pop(workspace, None)
            return
        logger.error("slack config token for workspace %s rotated but not saved; held in memory", workspace)
        raise SlackSetupError(SetupErrorCode.install_failed)
