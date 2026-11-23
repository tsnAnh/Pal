from __future__ import annotations

from enum import StrEnum
from urllib.parse import urlparse


class AppScheme(StrEnum):
    release = "dev.tsnanh.hermes.bot"
    development = "dev.tsnanh.hermes.bot.dev"

    @classmethod
    def parse(cls, raw: object) -> AppScheme:
        try:
            return cls(raw)
        except ValueError:
            return cls.release

    @classmethod
    def of_uri(cls, uri: object) -> AppScheme | None:
        scheme = urlparse(str(uri or "").strip()).scheme.lower()
        return cls(scheme) if scheme in cls._value2member_map_ else None

    def link(self, rest: str) -> str:
        return f"{self.value}:{rest}"


NONCE_COLUMN_DDL = f"app_scheme TEXT NOT NULL DEFAULT '{AppScheme.release.value}'"
