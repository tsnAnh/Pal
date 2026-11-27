from __future__ import annotations

import json
import re
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

from gateway.chat_install_service import ReloadOutcome
from tests.tui_gateway.contracts.chat_provider_fakes import FAKE_TOKEN
from tui_gateway import chat_providers

HTTPS = "https://pal.example.test"


class RecordingControl:
    def __init__(self) -> None:
        self.applied: list[tuple[str, str, dict[str, str], list[str]]] = []
        self.reloads: list[str] = []
        self.fail_apply = False
        self.reload_outcome = ReloadOutcome.live
        self.live: set[tuple[str, str]] = set()
        self.fail_live = False

    def apply_env(self, profile, platform_id, env, clear) -> None:
        if self.fail_apply:
            raise RuntimeError("apply exploded: provider secret text")
        self.applied.append((profile, platform_id, dict(env), list(clear)))

    def reload(self, profile) -> ReloadOutcome:
        self.reloads.append(profile)
        return self.reload_outcome

    def is_live(self, profile, platform_id) -> bool:
        if self.fail_live:
            raise RuntimeError("probe exploded: provider secret text")
        return (profile, platform_id) in self.live


def nonce_of(link: str) -> str:
    return parse_qs(urlsplit(link).query)["state"][0]


def _factory(provider):
    return lambda **deps: provider


def register_fakes(monkeypatch, *providers) -> None:
    monkeypatch.setattr(chat_providers, "PROVIDER_FACTORIES", {p.provider_id: _factory(p) for p in providers})


def forbidden_in(text: str, nonces: list[str] = ()) -> list[str]:
    return [needle for needle in (FAKE_TOKEN, "code-from-slack", *nonces) if needle and needle in text]


def walk_json(value) -> str:
    return json.dumps(value, sort_keys=True)


def db_bytes(root: Path) -> bytes:
    return b"".join(path.read_bytes() for path in root.rglob("chat_install.db*"))


NONCE_RE = re.compile(r"state=([A-Za-z0-9_\-]+)")
